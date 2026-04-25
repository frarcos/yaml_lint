/// The umbrella analysis rule that fronts every YAML-defined rule.
///
/// ## Why an umbrella?
///
/// `analysis_server_plugin` requires that every rule be known to the registry
/// at `Plugin.register()` time so it can populate `Registry.lintRules` and
/// resolve `analysis_options.yaml`'s `diagnostics:` block by rule name.
/// `register()` runs once at plugin process startup, **before** the analysis
/// server has told us anything about the projects it will be analyzing — so
/// when launched by the IDE we cannot possibly know the user's
/// `lint_rules.yaml` rule ids ahead of time. (`Directory.current` is the
/// consumer project for `dart analyze`, but the synthetic plugin-manager
/// directory when launched by the IDE.)
///
/// The fix is to register a single [MultiAnalysisRule] named `yaml_lint`
/// that:
///
///   1. Discovers the consumer's project root **lazily**, per-analysis,
///      from [RuleContext.package]. This is the per-package root the
///      analysis server itself computed from the consumer's `pubspec.yaml`.
///   2. Loads `lint_rules.yaml` for that root (via the existing
///      `loadProjectConfig` machinery), caching the result by
///      project root + YAML mtime.
///   3. Registers per-YAML-rule AST visitors against itself, so when a
///      visitor fires it calls `umbrella.reportAtNode(node, diagnosticCode:
///      perIdCode)` with a `LintCode` whose name matches the YAML rule's id.
///
/// ## What the consumer sees
///
/// `// ignore: yaml_lint/no_print` and severity routing both hinge on the
/// reported `DiagnosticCode`'s name, not on the rule's name. So even though
/// only one rule (`yaml_lint`) is registered, each YAML rule still surfaces
/// in the IDE as `yaml_lint/<id>` with its declared severity.
///
/// ## First-analysis severity caveat
///
/// `_computeDiagnosticsFromPlugin` (in `analysis_server_plugin`) builds its
/// `pluginCodeMapping` / `severityMapping` from `rule.diagnosticCodes`
/// **before** `registerNodeProcessors` runs. The very first library analyzed
/// in a brand-new project root therefore can't have its YAML codes mapped
/// yet — those diagnostics are still emitted (the framework keeps unmapped
/// diagnostics; see `plugin_server.dart:494`), but they fall back to the
/// default `INFO` severity. From the second analysis on (cache hit),
/// [diagnosticCodes] returns the union of every code we've seen and full
/// fidelity is restored. This is an inherent consequence of "discovery
/// happens during analysis"; it cannot be removed without the framework
/// exposing project roots at `register()` time.
library;

import 'dart:io';

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../config/loader.dart';
import '../config/models.dart';
import '../engine/conditions.dart';
import '../engine/constraints.dart';
import '../engine/rule_engine.dart';
import '../engine/target_router.dart';
import 'dynamic_yaml_rule.dart' show diagnosticSeverityFor;

/// Public name surfaced in `analysis_options.yaml`'s `diagnostics:` block.
const String kYamlLintRuleName = 'yaml_lint';

/// The rule registered by [YamlLintPlugin].
///
/// Singleton-like: there is exactly one instance per plugin process. State
/// it carries (the per-project compiled-rules cache, the union of discovered
/// codes) is therefore process-wide, scoped by project-root path.
class YamlLintRule extends MultiAnalysisRule implements RuleEngine {
  YamlLintRule({ProjectConfigResolver? resolver})
    : _resolver = resolver ?? const _RealProjectConfigResolver(),
      super(
        name: kYamlLintRuleName,
        description:
            'Aggregates every YAML-declared rule from the consumer project '
            "'s lint_rules.yaml. See https://pub.dev/packages/yaml_lint.",
      );

  final ProjectConfigResolver _resolver;

  /// Compiled rule sets, keyed by absolute project root path.
  final Map<String, _CompiledProject> _byRoot = {};

  /// Union of every [LintCode] we have ever discovered, keyed by the lower-
  /// case unique name to dedupe across multiple project roots.
  ///
  /// Returned by [diagnosticCodes] so that subsequent analyses populate
  /// `pluginCodeMapping` / `severityMapping` correctly (see library doc).
  final Map<String, LintCode> _allCodes = {};

  /// Per-analysis [EngineContext], set at the start of every
  /// [registerNodeProcessors] call and read during the visit phase by
  /// [onTargetMatched] to power `follow_calls:` recursion.
  ///
  /// `analysis_server_plugin` runs registration and the AST walk
  /// synchronously per isolate, so a single field is safe — there's
  /// never a second analysis interleaved on the same rule instance.
  EngineContext? _activeEngineContext;

  @override
  List<DiagnosticCode> get diagnosticCodes =>
      List<DiagnosticCode>.unmodifiable(_allCodes.values);

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    final root = resolveProjectRoot(context);
    if (root == null) return;

    final compiled = _loadCached(root);
    if (compiled == null) return;

    // Refresh per-analysis engine context. Built lazily — the BFS body
    // map inside [EngineContext] is only computed if a rule actually
    // reads it (i.e. has `follow_calls:` set), so rules-without-follow
    // pay nothing.
    //
    // `allUnits` access is wrapped: some embeddings have historically
    // thrown before exposing it. When unavailable we still build an
    // EngineContext with whatever units we can reach, so non-follow
    // rules continue to work.
    List<CompilationUnit> units;
    try {
      units = [for (final u in context.allUnits) u.unit];
    } catch (_) {
      units = const <CompilationUnit>[];
    }
    _activeEngineContext = EngineContext(
      allUnits: units,
      projectRoot: root,
    );

    final filePath = _safeFilePath(context);
    final relPath = filePath != null ? _relativeTo(root, filePath) : null;

    for (final entry in compiled.rules) {
      // `scope:` is a *file-level* pre-filter. Skip registration entirely
      // for rules whose `scope:` rejects this file — that means we don't
      // even build a visitor, so excluded files pay zero AST-walk cost.
      if (relPath != null && !_scopeAllows(entry.spec.scope, relPath)) {
        continue;
      }
      registerTargetVisitor(
        registry: registry,
        rule: this,
        engine: this,
        spec: entry.spec,
        code: entry.code,
      );
    }
  }

  /// [RuleEngine] entry point.
  ///
  /// Pipeline order, top-down:
  ///   1. `when:` evaluation. A failing `when:` bails before constraints
  ///      are even examined.
  ///   2. Constraints (`must_contain`, `must_not_contain`, `count`).
  ///   3. Diagnostic emission.
  @override
  void onTargetMatched({
    required RuleConfig spec,
    required LintCode code,
    required AstNode reportAt,
    required AstNode scope,
  }) {
    final when = spec.when;
    if (when != null) {
      final filePath = _filePathOf(reportAt) ?? '';
      final root = _projectRootFor(filePath);
      final ctx = ConditionContext(
        matchedNode: reportAt,
        filePath: filePath,
        projectRoot: root,
        layers: root == null ? null : _byRoot[root]?.layers,
      );
      if (!_conditions.evaluate(when, ctx)) return;
    }
    if (!_constraints.shouldReport(
      scope: scope,
      spec: spec,
      context: _activeEngineContext,
    )) {
      return;
    }
    reportAtNode(reportAt, diagnosticCode: code);
  }

  /// Returns the deepest cached project root that contains [filePath],
  /// or `null` if no cached root applies. Monorepo / nested-pkg safe.
  String? _projectRootFor(String filePath) {
    String? best;
    for (final root in _byRoot.keys) {
      if (p.isWithin(root, filePath) || p.equals(root, filePath)) {
        if (best == null || root.length > best.length) best = root;
      }
    }
    return best;
  }

  static const ConstraintsEngine _constraints = ConstraintsEngine();
  static const ConditionEvaluator _conditions = ConditionEvaluator();

  /// Walk up to the enclosing [CompilationUnit] and read the resolved
  /// source path from its [LibraryFragment]. Returns `null` only for the
  /// (currently unreachable) case of an unresolved unit.
  static String? _filePathOf(AstNode node) {
    final unit = node.thisOrAncestorOfType<CompilationUnit>();
    return unit?.declaredFragment?.source.fullName;
  }

  /// Best-effort startup-time warm-up for the `dart analyze` /
  /// `flutter analyze` case.
  ///
  /// `Plugin.register()` runs once per plugin process. For one-shot CLI
  /// invocations (`dart analyze`) the process is short-lived: a single
  /// `_computeDiagnosticsFromPlugin` cycle, no chance to "build the cache
  /// over time". If we waited for `registerNodeProcessors` to discover the
  /// project, the framework would have already built `pluginCodeMapping`
  /// from an empty [diagnosticCodes], and **every** diagnostic would be
  /// emitted as `INFO` and any `// ignore:` comments would be silently
  /// bypassed.
  ///
  /// In the CLI case `Directory.current.path` is the consumer project. We
  /// use it as a hint here: if it points at a project with a
  /// `lint_rules.yaml`, pre-populate the cache. The full lazy resolver still
  /// runs per analysis context for IDE-launched isolates (where this hint is
  /// a no-op because `Directory.current` is the synthetic plugin-manager
  /// directory).
  ///
  /// Failures are swallowed: this is purely an optimization.
  void warmUpFromCwd() {
    try {
      final root = _findEnclosingPackage(Directory.current.path);
      if (root != null) _loadCached(root);
    } catch (_) {
      // Any failure here is recoverable — `registerNodeProcessors` will
      // fall back to per-context discovery during the first analysis.
    }
  }

  /// Test hook: drives the same code path that `registerNodeProcessors`
  /// hits, but returns a coarse summary instead of the private
  /// [_CompiledProject]. Tests use this to assert cache hits, mtime
  /// invalidation, and the union of [diagnosticCodes].
  @visibleForTesting
  int debugLoadFor(String projectRoot) =>
      _loadCached(projectRoot)?.rules.length ?? 0;

  _CompiledProject? _loadCached(String projectRoot) {
    final mtime = _resolver.entryFileMtime(projectRoot);
    final cached = _byRoot[projectRoot];
    if (cached != null && cached.mtime == mtime) return cached;

    final result = _resolver.load(projectRoot);
    final entries = <_CompiledRule>[];
    for (final spec in result.ruleSet.rules) {
      final code = _allCodes.putIfAbsent(
        _uniqueCodeName(spec.report.code),
        () => _toLintCode(spec),
      );
      entries.add(_CompiledRule(spec: spec, code: code));
    }

    final compiled = _CompiledProject(
      rules: entries,
      mtime: mtime,
      layers: result.ruleSet.layers,
    );
    _byRoot[projectRoot] = compiled;
    return compiled;
  }
}

/// Decides whether [relPath] (project-relative, forward-slashed) is
/// inside [scope]. A `null` or empty `scope:` is "match everything".
///
/// Semantics: include is OR (any glob matches); exclude wins over
/// include (matches → reject). Matches `package:glob`'s defaults.
bool _scopeAllows(ScopeSpec? scope, String relPath) {
  if (scope == null || scope.isEmpty) return true;
  if (scope.include.isNotEmpty) {
    if (!scope.include.any((g) => Glob(g).matches(relPath))) return false;
  }
  if (scope.exclude.any((g) => Glob(g).matches(relPath))) return false;
  return true;
}

String? _safeFilePath(RuleContext context) {
  try {
    return context.definingUnit.file.path;
  } catch (_) {
    return null;
  }
}

/// Returns [filePath] relative to [root], with `/` separators. The glob
/// matcher is path-style-aware but we normalise to POSIX so the same
/// `lint_rules.yaml` works on macOS / Linux / Windows alike.
String _relativeTo(String root, String filePath) {
  final rel = p.isWithin(root, filePath)
      ? p.relative(filePath, from: root)
      : filePath;
  return p.posix.joinAll(p.split(rel));
}

/// Visible for testing: turn a [RuleContext] into the consumer project root.
///
/// Preference order:
///
///   1. `context.package?.root.path` — the analysis server's own per-library
///      package resolution. This is the canonical answer for any file the
///      server is actually analyzing.
///   2. Fallback: walk up from the defining unit's file looking for the
///      nearest `pubspec.yaml`. Defensive — covers exotic embedders and
///      any future analyzer release that might leave [RuleContext.package]
///      null for files inside our scope.
String? resolveProjectRoot(RuleContext context) {
  final pkg = context.package;
  if (pkg != null) return pkg.root.path;

  try {
    final unitPath = context.definingUnit.file.path;
    return _findEnclosingPackage(p.dirname(unitPath));
  } catch (_) {
    return null;
  }
}

String? _findEnclosingPackage(String start) {
  var dir = Directory(p.absolute(start));
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

LintCode _toLintCode(RuleConfig spec) => _YamlLintLintCode(
  spec.report.code,
  spec.report.message,
  severity: diagnosticSeverityFor(spec.report.severity),
  url: spec.report.url?.toString(),
);

/// `LintCode` is the analyzer-public wrapper. As of analyzer 12.x it
/// has a `// TODO: add a 'url' parameter` (see
/// `lib/src/dart/error/lint_codes.dart`) and hard-codes `url => null`.
/// We override that single getter to surface `report.url:` through
/// `DiagnosticCode.url` (used by IDEs as the "more info" link in the
/// Problems panel). Everything else is delegated to the base class.
class _YamlLintLintCode extends LintCode {
  const _YamlLintLintCode(
    super.name,
    super.problemMessage, {
    super.severity,
    String? url,
  }) : _url = url;

  final String? _url;

  @override
  String? get url => _url;
}

/// Disambiguates two YAML rules from different projects that happen to share
/// a `report.code`. Keeping a single global [LintCode] per code keeps the
/// `pluginCodeMapping` stable — but if two projects ever defined different
/// *messages* under the same code we'd silently collapse them. Surfacing
/// that as a YAML-level diagnostic is a future improvement.
String _uniqueCodeName(String code) => code.toLowerCase();

class _CompiledProject {
  _CompiledProject({
    required this.rules,
    required this.mtime,
    required this.layers,
  });
  final List<_CompiledRule> rules;
  final DateTime? mtime;
  final Map<String, List<String>> layers;
}

class _CompiledRule {
  _CompiledRule({required this.spec, required this.code});
  final RuleConfig spec;
  final LintCode code;
}

/// Indirection between [YamlLintRule] and the disk, both for testability and
/// to make the lazy-load contract explicit.
abstract class ProjectConfigResolver {
  const ProjectConfigResolver();

  /// Modification time of the entry file under [projectRoot], or `null` if
  /// no entry file exists. Used by [YamlLintRule] as a cache key — when the
  /// mtime changes we recompile.
  DateTime? entryFileMtime(String projectRoot);

  /// Loads (and parses) the consumer's `lint_rules.yaml` under [projectRoot].
  ConfigLoadResult load(String projectRoot);
}

class _RealProjectConfigResolver extends ProjectConfigResolver {
  const _RealProjectConfigResolver();

  @override
  DateTime? entryFileMtime(String projectRoot) {
    for (final name in defaultConfigFileNames) {
      final candidate = p.normalize(p.join(projectRoot, name));
      final f = File(candidate);
      if (f.existsSync()) {
        try {
          return f.lastModifiedSync();
        } on FileSystemException {
          return null;
        }
      }
    }
    return null;
  }

  @override
  ConfigLoadResult load(String projectRoot) =>
      loadProjectConfig(projectRoot: projectRoot);
}

/// In-memory [ProjectConfigResolver] for tests of [YamlLintRule]'s cache.
class FakeProjectConfigResolver extends ProjectConfigResolver {
  FakeProjectConfigResolver({
    required ConfigLoadResult Function(String projectRoot) onLoad,
    DateTime? Function(String projectRoot)? onMtime,
  }) : _onLoad = onLoad,
       _onMtime = onMtime;

  final ConfigLoadResult Function(String projectRoot) _onLoad;
  final DateTime? Function(String projectRoot)? _onMtime;

  int loadCount = 0;

  @override
  DateTime? entryFileMtime(String projectRoot) =>
      _onMtime?.call(projectRoot) ?? DateTime.fromMillisecondsSinceEpoch(0);

  @override
  ConfigLoadResult load(String projectRoot) {
    loadCount++;
    return _onLoad(projectRoot);
  }
}
