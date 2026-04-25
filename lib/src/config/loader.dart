/// Locates `lint_rules.yaml`, parses it, and resolves `includes:` recursively
/// (cycle-safe).
///
/// Lookup order:
///   1. `<projectRoot>/lint_rules.yaml`
///   2. `<projectRoot>/.yaml_lint.yaml`
///
/// I/O is intentionally synchronous and minimal: this code runs inside the
/// Dart Analysis Server's plugin isolate where blocking on disk during
/// `register()` is acceptable but anything more is not.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'models.dart';
import 'parser.dart';

/// Default candidate filenames, in priority order.
const List<String> defaultConfigFileNames = [
  'lint_rules.yaml',
  '.yaml_lint.yaml',
];

/// Reads and merges `lint_rules.yaml` (plus any `includes:`) starting from
/// [projectRoot].
///
/// If no config file is found at all, returns an empty result with no
/// diagnostics — the consumer simply hasn't configured `yaml_lint` yet.
ConfigLoadResult loadProjectConfig({
  required String projectRoot,
  String? overridePath,
  ConfigFileSystem fs = const _RealFileSystem(),
}) {
  final entryFile = _resolveEntryFile(
    projectRoot: projectRoot,
    overridePath: overridePath,
    fs: fs,
  );
  if (entryFile == null) {
    return const ConfigLoadResult(ruleSet: RuleSet.empty, diagnostics: []);
  }

  final visited = <String>{};
  final diagnostics = <ConfigDiagnostic>[];
  final mergedRules = <RuleConfig>[];
  final seenIds = <String, RuleConfig>{};
  final mergedLayers = <String, List<String>>{};

  _loadInto(
    absolutePath: entryFile,
    visited: visited,
    diagnostics: diagnostics,
    mergedRules: mergedRules,
    seenIds: seenIds,
    mergedLayers: mergedLayers,
    fs: fs,
    includeOriginSpan: null,
  );

  return ConfigLoadResult(
    ruleSet: RuleSet(
      version: 1,
      rules: List.unmodifiable(mergedRules),
      sourceFile: entryFile,
      layers: Map<String, List<String>>.unmodifiable(mergedLayers),
    ),
    diagnostics: List.unmodifiable(diagnostics),
  );
}

String? _resolveEntryFile({
  required String projectRoot,
  required String? overridePath,
  required ConfigFileSystem fs,
}) {
  if (overridePath != null) {
    final abs = p.isAbsolute(overridePath)
        ? overridePath
        : p.normalize(p.join(projectRoot, overridePath));
    return fs.exists(abs) ? abs : null;
  }
  for (final name in defaultConfigFileNames) {
    final candidate = p.normalize(p.join(projectRoot, name));
    if (fs.exists(candidate)) return candidate;
  }
  return null;
}

void _loadInto({
  required String absolutePath,
  required Set<String> visited,
  required List<ConfigDiagnostic> diagnostics,
  required List<RuleConfig> mergedRules,
  required Map<String, RuleConfig> seenIds,
  required Map<String, List<String>> mergedLayers,
  required ConfigFileSystem fs,
  required SourceSpan? includeOriginSpan,
}) {
  if (!visited.add(absolutePath)) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            'Cyclic include detected for $absolutePath. '
            'Each YAML file may only be included once per chain.',
        span: includeOriginSpan,
      ),
    );
    return;
  }

  final String contents;
  try {
    contents = fs.readAsString(absolutePath);
  } on FileSystemException catch (e) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: 'Could not read $absolutePath: ${e.message}',
        span: includeOriginSpan,
      ),
    );
    return;
  }

  final parsed = parseRuleSet(yamlSource: contents, sourceFile: absolutePath);
  diagnostics.addAll(parsed.diagnostics);

  for (final rule in parsed.ruleSet.rules) {
    final prior = seenIds[rule.id];
    if (prior != null) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.warning,
          message:
              "Rule id '${rule.id}' is defined in both "
              '${_describeFile(prior.span)} and ${_describeFile(rule.span)}. '
              'The first definition wins; the duplicate is ignored.',
          span: rule.span,
        ),
      );
      continue;
    }
    seenIds[rule.id] = rule;
    mergedRules.add(rule);
  }

  // Merge `layers:` from each file. Earlier files win on conflicts —
  // matches our rule-merge policy and keeps the entry file authoritative.
  parsed.ruleSet.layers.forEach((name, paths) {
    mergedLayers.putIfAbsent(name, () => paths);
  });

  for (final include in _extractIncludes(contents, absolutePath)) {
    final resolved = p.isAbsolute(include.path)
        ? include.path
        : p.normalize(p.join(p.dirname(absolutePath), include.path));
    _loadInto(
      absolutePath: resolved,
      visited: visited,
      diagnostics: diagnostics,
      mergedRules: mergedRules,
      seenIds: seenIds,
      mergedLayers: mergedLayers,
      fs: fs,
      includeOriginSpan: include.span,
    );
  }
}

class _Include {
  const _Include(this.path, this.span);
  final String path;
  final SourceSpan span;
}

List<_Include> _extractIncludes(String contents, String sourceFile) {
  YamlNode root;
  try {
    root = loadYamlNode(contents, sourceUrl: Uri.file(sourceFile));
  } on YamlException {
    // The main parser will already have reported the syntax error.
    return const [];
  }
  if (root is! YamlMap) return const [];
  final node = root.nodes['includes'];
  if (node == null || node is! YamlList) return const [];
  final result = <_Include>[];
  for (var i = 0; i < node.length; i++) {
    final item = node.nodes[i];
    final value = item.value;
    if (value is String && value.isNotEmpty) {
      result.add(_Include(value, item.span));
    }
  }
  return result;
}

String _describeFile(SourceSpan span) {
  final url = span.sourceUrl;
  if (url == null) return '<unknown>';
  try {
    return p.relative(url.toFilePath());
  } catch (_) {
    return url.toString();
  }
}

/// Pluggable filesystem so the loader is unit-testable without disk I/O.
abstract class ConfigFileSystem {
  const ConfigFileSystem();
  bool exists(String absolutePath);
  String readAsString(String absolutePath);
}

class _RealFileSystem implements ConfigFileSystem {
  const _RealFileSystem();

  @override
  bool exists(String absolutePath) => File(absolutePath).existsSync();

  @override
  String readAsString(String absolutePath) =>
      File(absolutePath).readAsStringSync();
}

/// In-memory [ConfigFileSystem] for tests.
class InMemoryFileSystem implements ConfigFileSystem {
  InMemoryFileSystem(this._files);
  final Map<String, String> _files;

  @override
  bool exists(String absolutePath) => _files.containsKey(absolutePath);

  @override
  String readAsString(String absolutePath) {
    final v = _files[absolutePath];
    if (v == null) {
      throw FileSystemException('Not found', absolutePath);
    }
    return v;
  }
}
