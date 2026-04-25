/// YAML → typed model parser for `lint_rules.yaml`.
///
/// Design notes:
/// * Uses `package:yaml`'s `loadYamlNode`, which returns nodes that carry
///   their original [SourceSpan]. We propagate those spans into every model
///   (and every diagnostic) so callers can produce IDE-quality error
///   locations.
/// * Parsing is **partial-failure tolerant**: a malformed rule does not
///   prevent its siblings from loading. Each problem is recorded as a
///   [ConfigDiagnostic] so the consumer keeps useful lints while seeing what
///   to fix.
/// * No external state, no I/O. The loader (`loader.dart`) handles file
///   reading and `includes:` resolution before invoking us.
library;

import 'package:glob/glob.dart';
import 'package:source_span/source_span.dart';
import 'package:yaml/yaml.dart';

import 'models.dart';

/// Parses [yamlSource] (the raw contents of a `lint_rules.yaml`) into a
/// [RuleSet] + accompanying [ConfigDiagnostic]s.
///
/// [sourceFile] is the absolute path of the YAML file; embedded into the
/// returned [RuleSet] for downstream reporting.
ConfigLoadResult parseRuleSet({
  required String yamlSource,
  required String sourceFile,
}) {
  final diagnostics = <ConfigDiagnostic>[];

  YamlNode root;
  try {
    root = loadYamlNode(yamlSource, sourceUrl: Uri.file(sourceFile));
  } on YamlException catch (e) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: 'Invalid YAML: ${e.message}',
        span: e.span,
      ),
    );
    return ConfigLoadResult(
      ruleSet: const RuleSet(version: 1, rules: [], sourceFile: ''),
      diagnostics: diagnostics,
    );
  }

  if (root is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: 'Top level of lint_rules.yaml must be a map.',
        span: root.span,
      ),
    );
    return ConfigLoadResult(
      ruleSet: RuleSet(version: 1, rules: const [], sourceFile: sourceFile),
      diagnostics: diagnostics,
    );
  }

  final version = _parseVersion(root, diagnostics);

  final layers = _parseLayers(root: root, diagnostics: diagnostics);

  final rulesNode = root.nodes[YamlScalar.wrap('rules')];
  final rules = <RuleConfig>[];
  if (rulesNode == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.warning,
        message: "Missing top-level 'rules:' key. No lints will be applied.",
        span: root.span,
      ),
    );
  } else if (rulesNode is! YamlList) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'rules' must be a list of rule definitions.",
        span: rulesNode.span,
      ),
    );
  } else {
    final seenIds = <String>{};
    for (var i = 0; i < rulesNode.length; i++) {
      final node = rulesNode.nodes[i];
      final rule = _parseRule(
        index: i,
        node: node,
        diagnostics: diagnostics,
        seenIds: seenIds,
      );
      if (rule != null) rules.add(rule);
    }
  }

  return ConfigLoadResult(
    ruleSet: RuleSet(
      version: version,
      rules: List.unmodifiable(rules),
      sourceFile: sourceFile,
      layers: layers,
    ),
    diagnostics: List.unmodifiable(diagnostics),
  );
}

/// Parses the optional top-level `layers:` block.
///
/// Shape:
/// ```yaml
/// layers:
///   domain:
///     paths: ["lib/domain/**"]
///   data:
///     paths: ["lib/data/**"]
/// ```
/// Returns an unmodifiable map: layer name → its glob patterns. Bad
/// shapes are reported as diagnostics but never crash the parse.
Map<String, List<String>> _parseLayers({
  required YamlMap root,
  required List<ConfigDiagnostic> diagnostics,
}) {
  final node = root.nodes[YamlScalar.wrap('layers')];
  if (node == null) return const <String, List<String>>{};
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "Top-level 'layers' must be a map of layer name → spec.",
        span: node.span,
      ),
    );
    return const <String, List<String>>{};
  }

  final result = <String, List<String>>{};
  for (final entry in node.nodes.entries) {
    final keyNode = entry.key as YamlNode;
    final valueNode = entry.value;
    final layerName = keyNode.value;
    if (layerName is! String) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: 'Layer name must be a string.',
          span: keyNode.span,
        ),
      );
      continue;
    }
    if (valueNode is! YamlMap) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: "Layer '$layerName' must be a map with a 'paths:' list.",
          span: valueNode.span,
        ),
      );
      continue;
    }
    final paths = _parseGlobList(
      map: valueNode,
      key: 'paths',
      diagnostics: diagnostics,
      contextLabel: "layer '$layerName' paths",
    );
    _warnOnUnknownKeys(
      map: valueNode,
      knownKeys: const {'paths'},
      diagnostics: diagnostics,
      contextLabel: "layer '$layerName'",
    );
    result[layerName] = paths;
  }
  return Map<String, List<String>>.unmodifiable(result);
}

int _parseVersion(YamlMap root, List<ConfigDiagnostic> diagnostics) {
  final node = root.nodes[YamlScalar.wrap('version')];
  if (node == null) return 1;
  final value = node.value;
  if (value is int && value == 1) return 1;
  diagnostics.add(
    ConfigDiagnostic(
      severity: ConfigDiagnosticSeverity.warning,
      message: "Unsupported version '$value'. Only version 1 is supported.",
      span: node.span,
    ),
  );
  return 1;
}

RuleConfig? _parseRule({
  required int index,
  required YamlNode node,
  required List<ConfigDiagnostic> diagnostics,
  required Set<String> seenIds,
}) {
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: 'rules[$index] must be a map.',
        span: node.span,
      ),
    );
    return null;
  }

  final id = _requireString(
    map: node,
    key: 'id',
    diagnostics: diagnostics,
    contextLabel: 'rules[$index]',
  );
  if (id == null) return null;

  if (!_isValidIdentifier(id)) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "Rule id '$id' is invalid. Use snake_case "
            "(letters, digits, underscores; must start with a letter).",
        span: node.nodes[YamlScalar.wrap('id')]!.span,
      ),
    );
    return null;
  }

  if (!seenIds.add(id)) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "Duplicate rule id '$id'. Each rule id must be unique.",
        span: node.nodes[YamlScalar.wrap('id')]!.span,
      ),
    );
    return null;
  }

  final description = _optionalString(map: node, key: 'description');

  final target = _parseTarget(
    parent: node,
    diagnostics: diagnostics,
    ruleId: id,
  );
  if (target == null) return null;

  final whenNode = node.nodes[YamlScalar.wrap('when')];
  final when = whenNode == null
      ? null
      : _parseCondition(
          node: whenNode,
          diagnostics: diagnostics,
          ruleId: id,
        );

  final mustContain = _parseConstraintSpec(
    parent: node,
    key: 'must_contain',
    diagnostics: diagnostics,
    ruleId: id,
  );
  final mustNotContain = _parseConstraintSpec(
    parent: node,
    key: 'must_not_contain',
    diagnostics: diagnostics,
    ruleId: id,
  );
  final count = _parseCountSpec(
    parent: node,
    diagnostics: diagnostics,
    ruleId: id,
  );

  final scope = _parseScopeSpec(
    parent: node,
    diagnostics: diagnostics,
    ruleId: id,
  );

  final followCalls = _parseFollowCallsSpec(
    parent: node,
    diagnostics: diagnostics,
    ruleId: id,
  );

  final report = _parseReport(
    parent: node,
    diagnostics: diagnostics,
    defaultCode: id,
  );
  if (report == null) return null;

  if (followCalls != null &&
      mustContain == null &&
      mustNotContain == null &&
      count == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.warning,
        message:
            "rule '$id' sets 'follow_calls:' but has no constraints "
            "(must_contain / must_not_contain / count) to apply it to. "
            "The setting will be ignored.",
        span: followCalls.span,
      ),
    );
  }

  _warnOnUnknownKeys(
    map: node,
    knownKeys: const {
      'id',
      'description',
      'target',
      'when',
      'must_contain',
      'must_not_contain',
      'count',
      'scope',
      'follow_calls',
      'report',
    },
    diagnostics: diagnostics,
    contextLabel: "rule '$id'",
  );

  return RuleConfig(
    id: id,
    description: description,
    target: target,
    when: when,
    mustContain: mustContain,
    mustNotContain: mustNotContain,
    count: count,
    scope: scope,
    followCalls: followCalls,
    report: report,
    span: node.span,
  );
}

/// Parses a [YamlNode] inside `when:` (or recursively inside `all:` /
/// `any:` / `not:`) into a typed [Condition] subclass.
///
/// Returns `null` and emits diagnostics on parse failures, but never
/// throws — a malformed `when:` shouldn't kill the whole rule set.
Condition? _parseCondition({
  required YamlNode node,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': condition must be a map (e.g. "
            "'inside_widget: GestureDetector', 'all: [...]').",
        span: node.span,
      ),
    );
    return null;
  }

  // A `when:` map must have exactly one key — that key picks the
  // operator (`all`/`any`/`not`) or the leaf predicate. This makes the
  // grammar unambiguous and gives parse-time clarity to authors.
  if (node.length != 1) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': a condition map must have exactly one key "
            '(use `all:`, `any:`, `not:`, or a leaf predicate). Got '
            '${node.length} keys.',
        span: node.span,
      ),
    );
    return null;
  }

  final keyNode = node.nodes.keys.first;
  final keyValue = (keyNode as YamlScalar).value;
  if (keyValue is! String) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "rule '$ruleId': condition key must be a string.",
        span: keyNode.span,
      ),
    );
    return null;
  }
  final value = node.nodes.values.first;

  switch (keyValue) {
    case 'all':
      return _parseBooleanList(
        keyNode: keyNode,
        valueNode: value,
        diagnostics: diagnostics,
        ruleId: ruleId,
        builder: (children, span) =>
            AllCondition(children: children, span: span),
      );
    case 'any':
      return _parseBooleanList(
        keyNode: keyNode,
        valueNode: value,
        diagnostics: diagnostics,
        ruleId: ruleId,
        builder: (children, span) =>
            AnyCondition(children: children, span: span),
      );
    case 'not':
      final child = _parseCondition(
        node: value,
        diagnostics: diagnostics,
        ruleId: ruleId,
      );
      if (child == null) return null;
      return NotCondition(child: child, span: node.span);

    case 'inside_widget':
      final name = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': inside_widget",
      );
      if (name == null) return null;
      return InsideWidgetCondition(widgetName: name, span: node.span);

    case 'inside_class_annotated_with':
      final name = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel:
            "rule '$ruleId': inside_class_annotated_with",
      );
      if (name == null) return null;
      return InsideClassAnnotatedWithCondition(
        annotationName: name,
        span: node.span,
      );

    case 'file_matches':
      final glob = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': file_matches",
      );
      if (glob == null) return null;
      return FileMatchesCondition(glob: glob, span: node.span);

    case 'file_path':
      return _parseFilePath(
        valueNode: value,
        diagnostics: diagnostics,
        ruleId: ruleId,
        span: node.span,
      );

    case 'callback_body_contains':
      final names = _coerceStringList(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': callback_body_contains",
      );
      if (names == null) return null;
      return CallbackBodyContainsCondition(
        methodNames: names,
        span: node.span,
      );

    case 'callback_body_not_contains':
      final names = _coerceStringList(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': callback_body_not_contains",
      );
      if (names == null) return null;
      return CallbackBodyNotContainsCondition(
        methodNames: names,
        span: node.span,
      );

    case 'class_name_matches':
      final pattern = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': class_name_matches",
      );
      if (pattern == null) return null;
      // Validate the regex eagerly so authors see the error in the YAML,
      // not at the first analysis tick.
      try {
        RegExp(pattern);
      } on FormatException catch (e) {
        diagnostics.add(
          ConfigDiagnostic(
            severity: ConfigDiagnosticSeverity.error,
            message:
                "rule '$ruleId': class_name_matches regex is invalid: "
                '${e.message}',
            span: value.span,
          ),
        );
        return null;
      }
      return ClassNameMatchesCondition(regex: pattern, span: node.span);

    case 'method_name_starts_with':
      final prefix = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': method_name_starts_with",
      );
      if (prefix == null) return null;
      return MethodNameStartsWithCondition(
        prefix: prefix,
        span: node.span,
      );

    case 'import_from_layer':
      final layer = _expectScalarString(
        node: value,
        diagnostics: diagnostics,
        contextLabel: "rule '$ruleId': import_from_layer",
      );
      if (layer == null) return null;
      return ImportFromLayerCondition(layer: layer, span: node.span);

    default:
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "rule '$ruleId': unknown condition '$keyValue'. "
              'Valid keys: all, any, not, inside_widget, '
              'inside_class_annotated_with, file_matches, file_path, '
              'callback_body_contains, callback_body_not_contains, '
              'class_name_matches, method_name_starts_with, '
              'import_from_layer.',
          span: keyNode.span,
        ),
      );
      return null;
  }
}

Condition? _parseBooleanList({
  required YamlNode keyNode,
  required YamlNode valueNode,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
  required Condition Function(List<Condition> children, SourceSpan span)
  builder,
}) {
  if (valueNode is! YamlList) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': '${(keyNode as YamlScalar).value}' must be "
            'a list of conditions.',
        span: valueNode.span,
      ),
    );
    return null;
  }
  final children = <Condition>[];
  for (var i = 0; i < valueNode.length; i++) {
    final child = _parseCondition(
      node: valueNode.nodes[i],
      diagnostics: diagnostics,
      ruleId: ruleId,
    );
    if (child != null) children.add(child);
  }
  if (children.isEmpty) return null;
  return builder(children, valueNode.span);
}

Condition? _parseFilePath({
  required YamlNode valueNode,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
  required SourceSpan span,
}) {
  if (valueNode is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': 'file_path' must be a map "
            "(e.g. {starts_with: 'lib/domain/'}).",
        span: valueNode.span,
      ),
    );
    return null;
  }
  String? startsWith;
  String? endsWith;
  String? contains;
  String? regex;
  for (final entry in valueNode.nodes.entries) {
    final keyNode = entry.key;
    if (keyNode is! YamlScalar) continue;
    final keyValue = keyNode.value;
    if (keyValue is! String) continue;
    final s = _expectScalarString(
      node: entry.value,
      diagnostics: diagnostics,
      contextLabel: "rule '$ruleId': file_path.$keyValue",
    );
    if (s == null) continue;
    switch (keyValue) {
      case 'starts_with':
        startsWith = s;
      case 'ends_with':
        endsWith = s;
      case 'contains':
        contains = s;
      case 'regex':
        try {
          RegExp(s);
        } on FormatException catch (e) {
          diagnostics.add(
            ConfigDiagnostic(
              severity: ConfigDiagnosticSeverity.error,
              message:
                  "rule '$ruleId': file_path.regex is invalid: ${e.message}",
              span: entry.value.span,
            ),
          );
          continue;
        }
        regex = s;
      default:
        diagnostics.add(
          ConfigDiagnostic(
            severity: ConfigDiagnosticSeverity.warning,
            message:
                "rule '$ruleId': unknown file_path key '$keyValue'. "
                'Valid keys: starts_with, ends_with, contains, regex.',
            span: keyNode.span,
          ),
        );
    }
  }
  if (startsWith == null &&
      endsWith == null &&
      contains == null &&
      regex == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': 'file_path' needs at least one of "
            'starts_with / ends_with / contains / regex.',
        span: valueNode.span,
      ),
    );
    return null;
  }
  return FilePathCondition(
    startsWith: startsWith,
    endsWith: endsWith,
    contains: contains,
    regex: regex,
    span: span,
  );
}

String? _expectScalarString({
  required YamlNode node,
  required List<ConfigDiagnostic> diagnostics,
  required String contextLabel,
}) {
  final value = node.value;
  if (value is! String || value.isEmpty) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: '$contextLabel must be a non-empty string.',
        span: node.span,
      ),
    );
    return null;
  }
  return value;
}

ConstraintSpec? _parseConstraintSpec({
  required YamlMap parent,
  required String key,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final node = parent.nodes[YamlScalar.wrap(key)];
  if (node == null) return null;
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': '$key' must be a map of "
            '<target_type>: [<name>, ...].',
        span: node.span,
      ),
    );
    return null;
  }

  final entries = <ConstraintEntry>[];
  final seenTypes = <RuleTargetType>{};
  for (final mapEntry in node.nodes.entries) {
    final keyNode = mapEntry.key;
    if (keyNode is! YamlScalar) continue;
    final keyValue = keyNode.value;
    if (keyValue is! String) continue;
    final type = RuleTargetType.fromYaml(keyValue);
    if (type == null) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "Unknown target type '$keyValue' under '$key'. "
              'Valid values: '
              "${RuleTargetType.values.map((t) => "'${t.yamlName}'").join(', ')}.",
          span: keyNode.span,
        ),
      );
      continue;
    }
    if (!seenTypes.add(type)) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.warning,
          message:
              "rule '$ruleId': duplicate target type '$keyValue' under "
              "'$key'; the second occurrence is ignored.",
          span: keyNode.span,
        ),
      );
      continue;
    }
    final valueNode = mapEntry.value;
    final names = _coerceStringList(
      node: valueNode,
      diagnostics: diagnostics,
      contextLabel: "'$key.$keyValue'",
    );
    if (names == null) continue;
    entries.add(
      ConstraintEntry(
        targetType: type,
        names: names,
        span: keyNode.span,
      ),
    );
  }

  if (entries.isEmpty) return null;
  return ConstraintSpec(entries: entries, span: node.span);
}

CountSpec? _parseCountSpec({
  required YamlMap parent,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final node = parent.nodes[YamlScalar.wrap('count')];
  if (node == null) return null;
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "rule '$ruleId': 'count' must be a map.",
        span: node.span,
      ),
    );
    return null;
  }

  // count.target: the target type to count occurrences of. Required.
  // The `count: { target: method_call, names: [...] }` shape mirrors
  // the top-level `target:` block but is always single-typed.
  final targetNode = node.nodes[YamlScalar.wrap('target')];
  if (targetNode == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "rule '$ruleId': 'count' is missing required 'target'.",
        span: node.span,
      ),
    );
    return null;
  }
  final targetRaw = targetNode.value;
  if (targetRaw is! String) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "rule '$ruleId': 'count.target' must be a string.",
        span: targetNode.span,
      ),
    );
    return null;
  }
  final type = RuleTargetType.fromYaml(targetRaw);
  if (type == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': unknown 'count.target' value '$targetRaw'.",
        span: targetNode.span,
      ),
    );
    return null;
  }

  final names =
      _parseStringList(map: node, key: 'names', diagnostics: diagnostics) ??
      const <String>[];

  final exactly = _parsePositiveInt(
    map: node,
    key: 'exactly',
    diagnostics: diagnostics,
    ruleId: ruleId,
  );
  final min = _parsePositiveInt(
    map: node,
    key: 'min',
    diagnostics: diagnostics,
    ruleId: ruleId,
  );
  final max = _parsePositiveInt(
    map: node,
    key: 'max',
    diagnostics: diagnostics,
    ruleId: ruleId,
  );

  if (exactly == null && min == null && max == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': 'count' needs at least one of "
            "'exactly', 'min', or 'max'.",
        span: node.span,
      ),
    );
    return null;
  }

  if (exactly != null && (min != null || max != null)) {
    // These are mutually exclusive. Drop the broader bounds — `exactly`
    // is strictly tighter so that's the user's likely intent.
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.warning,
        message:
            "rule '$ruleId': 'count.exactly' is mutually exclusive with "
            "'min'/'max'; the latter are ignored.",
        span: node.span,
      ),
    );
    return CountSpec(
      targetType: type,
      names: names,
      exactly: exactly,
      span: node.span,
    );
  }

  if (min != null && max != null && min > max) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': 'count.min' ($min) is greater than "
            "'count.max' ($max).",
        span: node.span,
      ),
    );
    return null;
  }

  _warnOnUnknownKeys(
    map: node,
    knownKeys: const {'target', 'names', 'exactly', 'min', 'max'},
    diagnostics: diagnostics,
    contextLabel: "rule '$ruleId' count",
  );

  return CountSpec(
    targetType: type,
    names: names,
    min: min,
    max: max,
    exactly: exactly,
    span: node.span,
  );
}

/// Parses an optional `scope:` block on a rule.
///
/// Shape:
/// ```yaml
/// scope:
///   include: [glob, ...]
///   exclude: [glob, ...]
/// ```
/// Both lists are optional. Globs are validated eagerly with `package:glob`
/// so authors get the diagnostic on the YAML file rather than at lint time.
ScopeSpec? _parseScopeSpec({
  required YamlMap parent,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final scopeNode = parent.nodes[YamlScalar.wrap('scope')];
  if (scopeNode == null) return null;
  if (scopeNode is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "rule '$ruleId': 'scope' must be a map.",
        span: scopeNode.span,
      ),
    );
    return null;
  }

  final include = _parseGlobList(
    map: scopeNode,
    key: 'include',
    diagnostics: diagnostics,
    contextLabel: "rule '$ruleId' scope.include",
  );
  final exclude = _parseGlobList(
    map: scopeNode,
    key: 'exclude',
    diagnostics: diagnostics,
    contextLabel: "rule '$ruleId' scope.exclude",
  );

  _warnOnUnknownKeys(
    map: scopeNode,
    knownKeys: const {'include', 'exclude'},
    diagnostics: diagnostics,
    contextLabel: "rule '$ruleId' scope",
  );

  return ScopeSpec(
    include: include,
    exclude: exclude,
    span: scopeNode.span,
  );
}

/// Parses the optional `follow_calls:` block on a rule.
///
/// Three YAML shapes are accepted:
/// * `follow_calls: <int>` — sugar for `{max_depth: <int>, same_package_only: true}`.
/// * `follow_calls: false` — explicit "off"; same as omitting the key.
/// * `follow_calls: { max_depth: …, same_package_only: … }` — full form.
///
/// Returns `null` to mean "recursion disabled". A negative or zero
/// `max_depth` is normalised to "off" with a warning, so consumers
/// don't accidentally pay for a Spec they never wanted.
FollowCallsSpec? _parseFollowCallsSpec({
  required YamlMap parent,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final node = parent.nodes[YamlScalar.wrap('follow_calls')];
  if (node == null) return null;

  final value = node.value;

  if (value is bool) {
    if (value) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "rule '$ruleId': 'follow_calls: true' is not a valid shorthand. "
              "Use an integer depth (e.g. 'follow_calls: 1') or a full map.",
          span: node.span,
        ),
      );
    }
    return null;
  }

  if (value is int) {
    if (value < 0) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "rule '$ruleId': 'follow_calls' depth must be ≥ 0; got $value.",
          span: node.span,
        ),
      );
      return null;
    }
    if (value == 0) return null;
    return FollowCallsSpec(
      maxDepth: value,
      samePackageOnly: true,
      span: node.span,
    );
  }

  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': 'follow_calls' must be an int "
            "(e.g. 'follow_calls: 1'), 'false', or a map "
            "with 'max_depth' / 'same_package_only'.",
        span: node.span,
      ),
    );
    return null;
  }

  final maxDepthNode = node.nodes[YamlScalar.wrap('max_depth')];
  int? maxDepth;
  if (maxDepthNode != null) {
    final v = maxDepthNode.value;
    if (v is! int || v < 0) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "rule '$ruleId': follow_calls.max_depth must be a "
              "non-negative integer; got '$v'.",
          span: maxDepthNode.span,
        ),
      );
    } else {
      maxDepth = v;
    }
  } else {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': follow_calls map is missing required "
            "'max_depth' key.",
        span: node.span,
      ),
    );
  }

  final samePackageNode = node.nodes[YamlScalar.wrap('same_package_only')];
  var samePackageOnly = true;
  if (samePackageNode != null) {
    final v = samePackageNode.value;
    if (v is! bool) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message:
              "rule '$ruleId': follow_calls.same_package_only must be "
              "'true' or 'false'; got '$v'.",
          span: samePackageNode.span,
        ),
      );
    } else {
      samePackageOnly = v;
      if (!v) {
        diagnostics.add(
          ConfigDiagnostic(
            severity: ConfigDiagnosticSeverity.warning,
            message:
                "rule '$ruleId': 'same_package_only: false' is accepted "
                "but the engine currently can't follow calls outside the "
                "current library; cross-library follows will be skipped.",
            span: samePackageNode.span,
          ),
        );
      }
    }
  }

  _warnOnUnknownKeys(
    map: node,
    knownKeys: const {'max_depth', 'same_package_only'},
    diagnostics: diagnostics,
    contextLabel: "rule '$ruleId' follow_calls",
  );

  if (maxDepth == null || maxDepth == 0) return null;

  return FollowCallsSpec(
    maxDepth: maxDepth,
    samePackageOnly: samePackageOnly,
    span: node.span,
  );
}

List<String> _parseGlobList({
  required YamlMap map,
  required String key,
  required List<ConfigDiagnostic> diagnostics,
  required String contextLabel,
}) {
  final node = map.nodes[YamlScalar.wrap(key)];
  if (node == null) return const <String>[];
  if (node is! YamlList) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "$contextLabel: '$key' must be a list of glob strings.",
        span: node.span,
      ),
    );
    return const <String>[];
  }

  final result = <String>[];
  for (var i = 0; i < node.length; i++) {
    final entry = node.nodes[i];
    final value = entry.value;
    if (value is! String) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: '$contextLabel[$i] must be a string.',
          span: entry.span,
        ),
      );
      continue;
    }
    try {
      Glob(value);
    } on FormatException catch (e) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: '$contextLabel[$i]: invalid glob "$value": ${e.message}',
          span: entry.span,
        ),
      );
      continue;
    }
    result.add(value);
  }
  return List.unmodifiable(result);
}

int? _parsePositiveInt({
  required YamlMap map,
  required String key,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final node = map.nodes[YamlScalar.wrap(key)];
  if (node == null) return null;
  final value = node.value;
  if (value is! int || value < 0) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "rule '$ruleId': '$key' must be a non-negative integer "
            "(got '$value').",
        span: node.span,
      ),
    );
    return null;
  }
  return value;
}

/// Like [_parseStringList] but operates on an already-resolved [node]
/// (used inside constraint maps where we have YAML map values, not a
/// parent map keyed by name).
List<String>? _coerceStringList({
  required YamlNode node,
  required List<ConfigDiagnostic> diagnostics,
  required String contextLabel,
}) {
  if (node is! YamlList) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: '$contextLabel must be a list of strings.',
        span: node.span,
      ),
    );
    return null;
  }
  final result = <String>[];
  for (var i = 0; i < node.length; i++) {
    final item = node.nodes[i];
    final value = item.value;
    if (value is! String || value.isEmpty) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: '$contextLabel[$i] must be a non-empty string.',
          span: item.span,
        ),
      );
      continue;
    }
    result.add(value);
  }
  return result;
}

TargetSpec? _parseTarget({
  required YamlMap parent,
  required List<ConfigDiagnostic> diagnostics,
  required String ruleId,
}) {
  final node = parent.nodes[YamlScalar.wrap('target')];
  if (node == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "Rule '$ruleId' is missing required 'target' block.",
        span: parent.span,
      ),
    );
    return null;
  }
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'target' must be a map.",
        span: node.span,
      ),
    );
    return null;
  }

  final typeNode = node.nodes[YamlScalar.wrap('type')];
  if (typeNode == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'target' is missing required 'type' field.",
        span: node.span,
      ),
    );
    return null;
  }
  final typeRaw = typeNode.value;
  if (typeRaw is! String) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'target.type' must be a string.",
        span: typeNode.span,
      ),
    );
    return null;
  }
  final type = RuleTargetType.fromYaml(typeRaw);
  if (type == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "Unknown target.type '$typeRaw'. "
            'Valid values: '
            "${RuleTargetType.values.map((t) => "'${t.yamlName}'").join(', ')}.",
        span: typeNode.span,
      ),
    );
    return null;
  }
  final names = _parseStringList(
    map: node,
    key: 'names',
    diagnostics: diagnostics,
  );

  return TargetSpec(
    type: type,
    names: names ?? const <String>[],
    span: node.span,
  );
}

ReportSpec? _parseReport({
  required YamlMap parent,
  required List<ConfigDiagnostic> diagnostics,
  required String defaultCode,
}) {
  final node = parent.nodes[YamlScalar.wrap('report')];
  if (node == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "Rule '$defaultCode' is missing required 'report' block.",
        span: parent.span,
      ),
    );
    return null;
  }
  if (node is! YamlMap) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'report' must be a map.",
        span: node.span,
      ),
    );
    return null;
  }

  final severityRaw = _requireString(
    map: node,
    key: 'severity',
    diagnostics: diagnostics,
    contextLabel: 'report',
  );
  if (severityRaw == null) return null;

  final severity = RuleSeverity.fromYaml(severityRaw);
  if (severity == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message:
            "Invalid severity '$severityRaw'. Use one of: error, warning, info.",
        span: node.nodes[YamlScalar.wrap('severity')]!.span,
      ),
    );
    return null;
  }

  final message = _requireString(
    map: node,
    key: 'message',
    diagnostics: diagnostics,
    contextLabel: 'report',
  );
  if (message == null) return null;

  final code = _optionalString(map: node, key: 'code') ?? defaultCode;

  Uri? url;
  final urlRaw = _optionalString(map: node, key: 'url');
  if (urlRaw != null) {
    try {
      url = Uri.parse(urlRaw);
    } on FormatException {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.warning,
          message: "report.url '$urlRaw' is not a valid URI; ignored.",
          span: node.nodes[YamlScalar.wrap('url')]!.span,
        ),
      );
    }
  }

  return ReportSpec(
    severity: severity,
    code: code,
    message: message,
    url: url,
    span: node.span,
  );
}

String? _requireString({
  required YamlMap map,
  required String key,
  required List<ConfigDiagnostic> diagnostics,
  required String contextLabel,
}) {
  final node = map.nodes[YamlScalar.wrap(key)];
  if (node == null) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "$contextLabel is missing required '$key' field.",
        span: map.span,
      ),
    );
    return null;
  }
  final value = node.value;
  if (value is! String || value.isEmpty) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'$key' must be a non-empty string.",
        span: node.span,
      ),
    );
    return null;
  }
  return value;
}

String? _optionalString({required YamlMap map, required String key}) {
  final value = map.nodes[YamlScalar.wrap(key)]?.value;
  return value is String ? value : null;
}

List<String>? _parseStringList({
  required YamlMap map,
  required String key,
  required List<ConfigDiagnostic> diagnostics,
}) {
  final node = map.nodes[YamlScalar.wrap(key)];
  if (node == null) return null;
  if (node is! YamlList) {
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.error,
        message: "'$key' must be a list of strings.",
        span: node.span,
      ),
    );
    return null;
  }
  final result = <String>[];
  for (var i = 0; i < node.length; i++) {
    final item = node.nodes[i];
    final value = item.value;
    if (value is! String || value.isEmpty) {
      diagnostics.add(
        ConfigDiagnostic(
          severity: ConfigDiagnosticSeverity.error,
          message: "$key[$i] must be a non-empty string.",
          span: item.span,
        ),
      );
      continue;
    }
    result.add(value);
  }
  return result;
}

void _warnOnUnknownKeys({
  required YamlMap map,
  required Set<String> knownKeys,
  required List<ConfigDiagnostic> diagnostics,
  required String contextLabel,
}) {
  for (final entry in map.nodes.entries) {
    final key = entry.key;
    if (key is! YamlScalar) continue;
    final keyValue = key.value;
    if (keyValue is! String) continue;
    if (knownKeys.contains(keyValue)) continue;
    final suggestion = _closestKey(keyValue, knownKeys);
    final hint = suggestion == null
        ? 'Valid keys: ${(knownKeys.toList()..sort()).join(', ')}.'
        : "Did you mean '$suggestion'?";
    diagnostics.add(
      ConfigDiagnostic(
        severity: ConfigDiagnosticSeverity.warning,
        message: "Unknown key '$keyValue' in $contextLabel. $hint",
        span: key.span,
      ),
    );
  }
}

/// Returns the most-similar key in [candidates] to [input], or `null`
/// when the closest match is too far away to be useful.
///
/// Uses Levenshtein distance with a generous-but-bounded threshold:
/// matches within `max(1, input.length ~/ 3)` edits are surfaced. This
/// catches typical typos (`severty` → `severity`, `messsage` →
/// `message`) without firing on totally-unrelated keys.
String? _closestKey(String input, Iterable<String> candidates) {
  String? best;
  var bestDistance = 1 << 30;
  for (final c in candidates) {
    final d = _levenshtein(input, c);
    if (d < bestDistance) {
      bestDistance = d;
      best = c;
    }
  }
  if (best == null) return null;
  final threshold = input.length ~/ 3;
  return bestDistance <= (threshold < 1 ? 1 : threshold) ? best : null;
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final n = a.length;
  final m = b.length;
  var prev = List<int>.generate(m + 1, (i) => i);
  var curr = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    curr[0] = i;
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      var minVal = del < ins ? del : ins;
      if (sub < minVal) minVal = sub;
      curr[j] = minVal;
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[m];
}

final RegExp _identifier = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

bool _isValidIdentifier(String s) => _identifier.hasMatch(s);
