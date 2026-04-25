import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/config/parser.dart';

ConfigLoadResult parse(String src) =>
    parseRuleSet(yamlSource: src, sourceFile: '/virtual/lint_rules.yaml');

void main() {
  group('parseRuleSet', () {
    test('parses a minimal valid rule', () {
      final result = parse('''
rules:
  - id: no_print
    target:
      type: method_call
      names: [print]
    report:
      severity: warning
      message: "Avoid print()"
''');

      expect(result.diagnostics, isEmpty);
      expect(result.ruleSet.rules, hasLength(1));

      final rule = result.ruleSet.rules.single;
      expect(rule.id, 'no_print');
      expect(rule.target.type, RuleTargetType.methodCall);
      expect(rule.target.names, ['print']);
      expect(rule.report.severity, RuleSeverity.warning);
      expect(rule.report.message, 'Avoid print()');
      expect(rule.report.code, 'no_print', reason: 'defaults to id');
    });

    test('uses explicit report.code when provided', () {
      final result = parse('''
rules:
  - id: no_print
    target: { type: method_call, names: [print] }
    report:
      severity: warning
      message: "x"
      code: stop_printing
''');
      expect(result.diagnostics, isEmpty);
      expect(result.ruleSet.rules.single.report.code, 'stop_printing');
    });

    test('rejects malformed YAML with line/col span', () {
      final result = parse('not: : yaml');
      expect(result.diagnostics, isNotEmpty);
      expect(result.diagnostics.first.severity, ConfigDiagnosticSeverity.error);
      expect(result.diagnostics.first.span?.start.line, isNonNegative);
    });

    test('flags missing id', () {
      final result = parse('''
rules:
  - target: { type: method_call }
    report: { severity: warning, message: x }
''');
      expect(
        result.diagnostics.map((d) => d.message),
        contains(contains("missing required 'id'")),
      );
      expect(result.ruleSet.rules, isEmpty);
    });

    test('flags duplicate ids', () {
      final result = parse('''
rules:
  - id: dupe
    target: { type: method_call }
    report: { severity: info, message: x }
  - id: dupe
    target: { type: method_call }
    report: { severity: info, message: x }
''');
      expect(
        result.diagnostics.map((d) => d.message),
        contains(contains('Duplicate rule id')),
      );
      expect(result.ruleSet.rules, hasLength(1));
    });

    test('flags invalid id', () {
      final result = parse('''
rules:
  - id: "1bad"
    target: { type: method_call }
    report: { severity: warning, message: x }
''');
      expect(
        result.diagnostics.map((d) => d.message),
        contains(contains('Use snake_case')),
      );
    });

    test('flags unknown target.type', () {
      final result = parse('''
rules:
  - id: x
    target: { type: nonsense }
    report: { severity: warning, message: x }
''');
      expect(
        result.diagnostics.map((d) => d.message),
        contains(contains('Unknown target.type')),
      );
    });

    test('all DSL v1 target types parse with no per-type warning', () {
      // Every `RuleTargetType` is implemented end-to-end by the engine. The
      // parser must accept each value without emitting a "not yet
      // implemented" warning; any such warning would falsely advertise a
      // feature gap.
      for (final type in RuleTargetType.values) {
        final result = parse('''
rules:
  - id: r_${type.yamlName}
    target: { type: ${type.yamlName}, names: [Foo] }
    report: { severity: warning, message: x }
''');
        expect(
          result.ruleSet.rules,
          hasLength(1),
          reason: 'target.type ${type.yamlName} should parse',
        );
        final messages = result.diagnostics.map((d) => d.message).join(' | ');
        expect(
          messages,
          isNot(contains("'${type.yamlName}'")),
          reason:
              'target.type ${type.yamlName} should not produce a per-type '
              'diagnostic',
        );
      }
    });

    test('partial failure tolerance: bad rule does not kill good rule', () {
      final result = parse('''
rules:
  - id: good
    target: { type: method_call, names: [foo] }
    report: { severity: info, message: ok }
  - target: { type: method_call }
    report: { severity: info, message: nope }
''');
      expect(result.ruleSet.rules, hasLength(1));
      expect(result.ruleSet.rules.single.id, 'good');
      expect(
        result.diagnostics.map((d) => d.message),
        contains(contains("missing required 'id'")),
      );
    });

    test('warns on unknown keys at rule scope', () {
      final result = parse('''
rules:
  - id: foo
    target: { type: method_call, names: [foo] }
    report: { severity: info, message: ok }
    severirty: error  # typo
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("Unknown key 'severirty'"),
      );
    });

    test('suggests the closest key for typos in rule scope', () {
      final result = parse('''
rules:
  - id: foo
    target: { type: method_call, names: [foo] }
    report: { severity: info, message: ok }
    descripton: oops  # typo for "description"
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("Did you mean 'description'?"),
      );
    });
  });

  group('follow_calls parser', () {
    String yaml(String body) => '''
rules:
  - id: r
    target: { type: named_argument, names: [onTap] }
    must_contain: { method_call: [Analytics.track] }
    follow_calls: $body
    report: { severity: warning, message: ok }
''';

    test('integer sugar form sets max_depth + samePackageOnly: true', () {
      final result = parse(yaml('2'));
      expect(result.diagnostics, isEmpty);
      final fc = result.ruleSet.rules.single.followCalls;
      expect(fc, isNotNull);
      expect(fc!.maxDepth, 2);
      expect(fc.samePackageOnly, isTrue);
    });

    test('"follow_calls: 0" disables (no spec)', () {
      final result = parse(yaml('0'));
      expect(result.diagnostics, isEmpty);
      expect(result.ruleSet.rules.single.followCalls, isNull);
    });

    test('"follow_calls: false" disables silently', () {
      final result = parse(yaml('false'));
      expect(result.diagnostics, isEmpty);
      expect(result.ruleSet.rules.single.followCalls, isNull);
    });

    test('"follow_calls: true" is rejected with a clear message', () {
      final result = parse(yaml('true'));
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("'follow_calls: true' is not a valid shorthand"),
      );
      expect(result.ruleSet.rules.single.followCalls, isNull);
    });

    test('negative max_depth is an error', () {
      final result = parse(yaml('-1'));
      expect(
        result.diagnostics.where(
          (d) => d.severity == ConfigDiagnosticSeverity.error,
        ),
        isNotEmpty,
      );
    });

    test('full map form: max_depth + same_package_only', () {
      final result = parse('''
rules:
  - id: r
    target: { type: named_argument, names: [onTap] }
    must_contain: { method_call: [Analytics.track] }
    follow_calls:
      max_depth: 3
      same_package_only: false
    report: { severity: warning, message: ok }
''');
      // same_package_only: false produces a warning (engine limitation)
      // but we still get a spec.
      expect(
        result.diagnostics.where(
          (d) => d.severity == ConfigDiagnosticSeverity.error,
        ),
        isEmpty,
      );
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("'same_package_only: false'"),
      );
      final fc = result.ruleSet.rules.single.followCalls;
      expect(fc, isNotNull);
      expect(fc!.maxDepth, 3);
      expect(fc.samePackageOnly, isFalse);
    });

    test('missing max_depth in map form is an error', () {
      final result = parse('''
rules:
  - id: r
    target: { type: named_argument, names: [onTap] }
    must_contain: { method_call: [Analytics.track] }
    follow_calls: { same_package_only: true }
    report: { severity: warning, message: ok }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("'max_depth'"),
      );
    });

    test('unknown key inside follow_calls suggests closest match', () {
      final result = parse('''
rules:
  - id: r
    target: { type: named_argument, names: [onTap] }
    must_contain: { method_call: [Analytics.track] }
    follow_calls:
      max_dept: 2  # typo for max_depth
    report: { severity: warning, message: ok }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("Did you mean 'max_depth'?"),
      );
    });

    test('follow_calls without any constraints emits a warning', () {
      final result = parse('''
rules:
  - id: r
    target: { type: named_argument, names: [onTap] }
    follow_calls: 2
    report: { severity: warning, message: ok }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('no constraints'),
      );
    });
  });
}
