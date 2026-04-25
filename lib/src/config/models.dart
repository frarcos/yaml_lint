/// Typed model of the `lint_rules.yaml` file.
///
/// This is the intermediate representation between raw YAML (a tree of
/// `YamlNode`s) and the runtime engine. The parser in `parser.dart` is the
/// only place `Map<String, dynamic>` is allowed to leak to; from here on, the
/// rest of the package operates on these typed models.
library;

import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';

/// Severity of a rule's reported diagnostic.
enum RuleSeverity {
  error,
  warning,
  info;

  static RuleSeverity? fromYaml(String raw) => switch (raw.toLowerCase()) {
    'error' => RuleSeverity.error,
    'warning' => RuleSeverity.warning,
    'info' => RuleSeverity.info,
    _ => null,
  };
}

/// What kind of AST node a rule targets.
///
/// Adding a new kind requires three coordinated edits: a new entry here,
/// parser acceptance in `parser.dart`, and a dispatch case in
/// `lib/src/engine/target_router.dart` plus a `SimpleAstVisitor` in
/// `lib/src/engine/target_visitors.dart`.
enum RuleTargetType {
  methodCall('method_call'),
  widget('widget'),
  constructor('constructor'),
  namedArgument('named_argument'),
  function('function'),
  classDeclaration('class'),
  importDirective('import'),
  annotation('annotation'),
  variableDeclaration('variable_declaration'),
  returnStatement('return_statement');

  const RuleTargetType(this.yamlName);

  final String yamlName;

  static RuleTargetType? fromYaml(String raw) {
    for (final t in RuleTargetType.values) {
      if (t.yamlName == raw) return t;
    }
    return null;
  }
}

/// What the rule looks at, e.g. "every method invocation named `print`".
@immutable
class TargetSpec {
  const TargetSpec({
    required this.type,
    required this.names,
    required this.span,
  });

  final RuleTargetType type;

  /// Names to match against. Empty == wildcard (match all of [type]).
  final List<String> names;

  /// Where this `target:` block lives in the source YAML, for diagnostics.
  final SourceSpan span;

  @override
  String toString() => 'TargetSpec(type: ${type.yamlName}, names: $names)';
}

/// One node in a `when:` predicate tree.
///
/// The DSL composes booleans (`all` / `any` / `not`) and leaf predicates.
/// We model each variant as a concrete subclass of this sealed hierarchy
/// so the evaluator's `switch` is exhaustive — adding a new predicate
/// without updating the evaluator is a compile error rather than a silent
/// skip.
sealed class Condition {
  const Condition({required this.span});

  /// Where this condition lives in the source YAML.
  final SourceSpan span;
}

/// `all: [<Condition>, ...]` — true iff every child evaluates true.
@immutable
class AllCondition extends Condition {
  const AllCondition({required this.children, required super.span});
  final List<Condition> children;
}

/// `any: [<Condition>, ...]` — true iff at least one child evaluates true.
@immutable
class AnyCondition extends Condition {
  const AnyCondition({required this.children, required super.span});
  final List<Condition> children;
}

/// `not: <Condition>` — boolean negation of a single child.
@immutable
class NotCondition extends Condition {
  const NotCondition({required this.child, required super.span});
  final Condition child;
}

/// `inside_widget: <Name>` — some ancestor of the matched node is an
/// `InstanceCreationExpression` of a class named [widgetName].
@immutable
class InsideWidgetCondition extends Condition {
  const InsideWidgetCondition({
    required this.widgetName,
    required super.span,
  });
  final String widgetName;
}

/// `inside_class_annotated_with: <A>` — the matched node's enclosing
/// class declaration carries an `@A` annotation.
@immutable
class InsideClassAnnotatedWithCondition extends Condition {
  const InsideClassAnnotatedWithCondition({
    required this.annotationName,
    required super.span,
  });
  final String annotationName;
}

/// `file_matches: <glob>` — the file under analysis matches the glob.
@immutable
class FileMatchesCondition extends Condition {
  const FileMatchesCondition({required this.glob, required super.span});
  final String glob;
}

/// `file_path: { starts_with: ... }` — a path predicate.
///
/// Exactly one of [startsWith] / [endsWith] / [contains] / [regex] is
/// non-null after parsing.
@immutable
class FilePathCondition extends Condition {
  const FilePathCondition({
    this.startsWith,
    this.endsWith,
    this.contains,
    this.regex,
    required super.span,
  });
  final String? startsWith;
  final String? endsWith;
  final String? contains;
  final String? regex;
}

/// `callback_body_contains: [m, ...]` — the *enclosing function body*
/// (the closest `FunctionBody` ancestor of the matched node) contains
/// at least one method call from [methodNames].
@immutable
class CallbackBodyContainsCondition extends Condition {
  const CallbackBodyContainsCondition({
    required this.methodNames,
    required super.span,
  });
  final List<String> methodNames;
}

/// `callback_body_not_contains: [m, ...]` — inverse of
/// [CallbackBodyContainsCondition].
@immutable
class CallbackBodyNotContainsCondition extends Condition {
  const CallbackBodyNotContainsCondition({
    required this.methodNames,
    required super.span,
  });
  final List<String> methodNames;
}

/// `class_name_matches: <regex>` — the matched node's enclosing class
/// declaration's name matches [regex].
@immutable
class ClassNameMatchesCondition extends Condition {
  const ClassNameMatchesCondition({
    required this.regex,
    required super.span,
  });
  final String regex;
}

/// `method_name_starts_with: <str>` — the matched node's enclosing
/// function or method declaration's name starts with [prefix].
@immutable
class MethodNameStartsWithCondition extends Condition {
  const MethodNameStartsWithCondition({
    required this.prefix,
    required super.span,
  });
  final String prefix;
}

/// `import_from_layer: <layer>` — the file under analysis imports
/// symbols from a layer declared at the top level under `layers:`.
@immutable
class ImportFromLayerCondition extends Condition {
  const ImportFromLayerCondition({
    required this.layer,
    required super.span,
  });
  final String layer;
}

/// One row of a `must_contain:` / `must_not_contain:` map.
///
/// In YAML this looks like:
///
/// ```yaml
/// must_contain:
///   method_call: [Analytics.track]
///   named_argument: [key]
/// ```
///
/// Each map entry becomes one [ConstraintEntry] — the row's key is the
/// [targetType], the row's value is [names].
///
/// Semantics differ between the two parents:
///
/// * Inside `must_contain:`, the rule fires when **any** of the listed
///   names is *missing* from the matched node's scope.
/// * Inside `must_not_contain:`, the rule fires when **any** of the listed
///   names is *present* in the matched node's scope.
@immutable
class ConstraintEntry {
  const ConstraintEntry({
    required this.targetType,
    required this.names,
    required this.span,
  });

  final RuleTargetType targetType;
  final List<String> names;
  final SourceSpan span;
}

/// A `must_contain:` or `must_not_contain:` block, modelled as an ordered
/// list of [ConstraintEntry] so duplicate keys (technically valid YAML)
/// surface as a parse-time diagnostic without losing data.
@immutable
class ConstraintSpec {
  const ConstraintSpec({required this.entries, required this.span});

  final List<ConstraintEntry> entries;
  final SourceSpan span;
}

/// A `count:` block.
///
/// Exactly one of [exactly] / ([min], [max]) is set per the parser; when
/// both `exactly:` and `min:`/`max:` appear, the parser keeps `exactly`
/// (it's narrower) and emits a `ConfigDiagnostic` so the user knows.
@immutable
class CountSpec {
  const CountSpec({
    required this.targetType,
    required this.names,
    this.min,
    this.max,
    this.exactly,
    required this.span,
  });

  final RuleTargetType targetType;
  final List<String> names;
  final int? min;
  final int? max;
  final int? exactly;
  final SourceSpan span;

  /// Returns true iff a count of [c] satisfies this spec.
  bool isSatisfiedBy(int c) {
    if (exactly != null) return c == exactly;
    if (min != null && c < min!) return false;
    if (max != null && c > max!) return false;
    return true;
  }
}

/// How a rule reports its violations.
@immutable
class ReportSpec {
  const ReportSpec({
    required this.severity,
    required this.code,
    required this.message,
    this.url,
    required this.span,
  });

  final RuleSeverity severity;

  /// Diagnostic code. Defaults to the rule's `id` when not set in YAML.
  final String code;

  /// Human-readable message shown in the IDE / `dart analyze`.
  final String message;

  /// Optional documentation URL surfaced in IDEs.
  final Uri? url;

  /// Where this `report:` block lives in the source YAML.
  final SourceSpan span;
}

/// `follow_calls:` block — opt-in recursive constraint evaluation.
///
/// By default, `must_contain` / `must_not_contain` / `count` only inspect
/// the AST scope handed in by the target visitor (e.g. the literal
/// closure body of `onTap: () { … }`). With `follow_calls:` set, the
/// engine also descends into the bodies of *project-local* functions
/// invoked from that scope, up to [maxDepth] levels deep.
///
/// Two YAML shapes are accepted:
///
/// ```yaml
/// follow_calls: 3                                # sugar form
/// follow_calls:                                  # full form
///   max_depth: 3
///   same_package_only: true
/// ```
///
/// `follow_calls: 0` and `follow_calls: false` both disable recursion
/// (the parser normalises both to `null`, i.e. "not set").
///
/// ## Cross-library / cross-package follow
///
/// The engine resolves callees against [RuleContext.allUnits] — the
/// main compilation unit and any `part of` files of the *current*
/// library. Calls into other libraries (whether in the same package or
/// not) cannot be reached without an analysis-driver lookup that the
/// public `analysis_server_plugin` API does not expose, so they are
/// silently skipped. Setting [samePackageOnly] to `false` flips that
/// silent-skip to "still skip with a YAML diagnostic at parse time"
/// — i.e. it documents that the consumer is asking for behaviour
/// the engine can't yet provide.
@immutable
class FollowCallsSpec {
  const FollowCallsSpec({
    required this.maxDepth,
    required this.samePackageOnly,
    required this.span,
  });

  /// Maximum recursion depth. Always ≥ 1 — a [FollowCallsSpec] is only
  /// constructed when the consumer opts into recursion at all.
  final int maxDepth;

  /// When `true` (the default), follow only into compilation units
  /// belonging to the same library as the file under analysis. When
  /// `false`, the parser still constructs the spec but emits a YAML
  /// warning explaining the engine limitation; behaviour at runtime
  /// is identical for now.
  final bool samePackageOnly;

  /// Where the `follow_calls:` block lives in the source YAML.
  final SourceSpan span;
}

/// `scope:` block — a per-rule file-level pre-filter.
///
/// Globs match against the file path the analyzer is currently
/// processing. Empty `include` means "match all"; empty `exclude`
/// means "exclude none". Both lists are matched with `package:glob`.
///
/// Pre-filtering happens *before* any AST walk: a rule whose `scope:`
/// rejects the current file never has its target visitor invoked, so
/// scope is effectively free.
@immutable
class ScopeSpec {
  const ScopeSpec({
    required this.include,
    required this.exclude,
    required this.span,
  });

  final List<String> include;
  final List<String> exclude;
  final SourceSpan span;

  bool get isEmpty => include.isEmpty && exclude.isEmpty;
}

/// A single rule definition, post-parse and post-validate.
@immutable
class RuleConfig {
  const RuleConfig({
    required this.id,
    this.description,
    required this.target,
    this.when,
    this.mustContain,
    this.mustNotContain,
    this.count,
    this.scope,
    this.followCalls,
    required this.report,
    required this.span,
  });

  /// `when:` predicate tree, or `null` when the rule has no
  /// pre-conditions. A rule with no `when:` runs on every target match.

  /// Unique within the rule set. The IDE surfaces this as
  /// `yaml_lint/<id>` for `// ignore:` comments and the Problems panel.
  final String id;

  /// Optional human-readable description of the rule.
  final String? description;

  final TargetSpec target;

  final Condition? when;

  /// `must_contain:`. When present, the rule only fires if the matched
  /// node's scope is *missing* one of the listed names.
  final ConstraintSpec? mustContain;

  /// `must_not_contain:`. When present, the rule only fires if the matched
  /// node's scope *contains* one of the listed names.
  final ConstraintSpec? mustNotContain;

  /// `count:`. When present, the rule fires if the count of matching
  /// nodes within the scope falls outside [CountSpec.exactly] /
  /// `[CountSpec.min, CountSpec.max]`.
  final CountSpec? count;

  /// `scope:` file-level pre-filter, or `null` for "match every file".
  final ScopeSpec? scope;

  /// `follow_calls:` recursive-traversal opt-in for constraints.
  /// `null` (default) means constraints only inspect the literal
  /// target scope.
  final FollowCallsSpec? followCalls;

  final ReportSpec report;

  /// Where this rule lives in the source YAML.
  final SourceSpan span;

  /// `true` when at least one of `must_contain` / `must_not_contain` /
  /// `count` is set. A rule with no constraints fires unconditionally on
  /// every target match.
  bool get hasConstraints =>
      mustContain != null || mustNotContain != null || count != null;

  @override
  String toString() => 'RuleConfig(id: $id, target: $target)';
}

/// The parsed contents of a `lint_rules.yaml`.
@immutable
class RuleSet {
  const RuleSet({
    required this.version,
    required this.rules,
    required this.sourceFile,
    this.layers = const <String, List<String>>{},
  });

  /// Currently always 1; bumped on breaking DSL changes.
  final int version;

  final List<RuleConfig> rules;

  /// Absolute path to the YAML file these rules came from. Used to report
  /// diagnostics back on the source.
  final String sourceFile;

  /// Top-level `layers:` block. Each entry maps a layer name (e.g.
  /// `domain`, `data`) to the list of glob patterns the layer covers.
  /// Empty when the consumer hasn't declared any layers.
  ///
  /// Used by `import_from_layer:` predicates and by architecture rules.
  final Map<String, List<String>> layers;

  static const RuleSet empty = RuleSet(version: 1, rules: [], sourceFile: '');
}

/// One problem found while parsing/validating YAML config.
///
/// Surfaced both via the CLI (`dart run yaml_lint:validate`) and as
/// analyzer diagnostics on the YAML file itself.
@immutable
class ConfigDiagnostic {
  const ConfigDiagnostic({
    required this.severity,
    required this.message,
    required this.span,
  });

  final ConfigDiagnosticSeverity severity;
  final String message;

  /// `null` only when the YAML couldn't even be tokenised.
  final SourceSpan? span;

  @override
  String toString() {
    final loc = span?.start;
    final where = loc == null ? '' : ' [${loc.line + 1}:${loc.column + 1}]';
    return '${severity.name}: $message$where';
  }
}

enum ConfigDiagnosticSeverity { error, warning }

/// Result of trying to load a `lint_rules.yaml`.
///
/// This is intentionally not a sealed `Either<...>`: parse failures and
/// successful-but-degraded loads (e.g. one bad rule among many good ones)
/// must coexist so the IDE can keep showing the good rules while flagging
/// the bad one.
@immutable
class ConfigLoadResult {
  const ConfigLoadResult({required this.ruleSet, required this.diagnostics});

  /// The rules that parsed cleanly. May be empty.
  final RuleSet ruleSet;

  /// Errors / warnings generated during load. May be empty.
  final List<ConfigDiagnostic> diagnostics;

  bool get hasErrors =>
      diagnostics.any((d) => d.severity == ConfigDiagnosticSeverity.error);
}
