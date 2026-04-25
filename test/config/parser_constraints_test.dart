/// Parser coverage for `must_contain`, `must_not_contain`, `count`.
library;

import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/config/parser.dart';

void main() {
  group('parseRuleSet (constraints)', () {
    test('parses must_contain with multiple target types', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: named_argument, names: [onTap] }
    must_contain:
      method_call: [Analytics.track]
      named_argument: [key]
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty);
      final spec = result.ruleSet.rules.single.mustContain!;
      expect(spec.entries, hasLength(2));
      expect(
        spec.entries.map((e) => e.targetType).toSet(),
        {RuleTargetType.methodCall, RuleTargetType.namedArgument},
      );
      expect(
        spec.entries
            .firstWhere((e) => e.targetType == RuleTargetType.methodCall)
            .names,
        ['Analytics.track'],
      );
    });

    test('parses must_not_contain', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [setUp] }
    must_not_contain:
      method_call: [print, debugPrint]
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty);
      final spec = result.ruleSet.rules.single.mustNotContain!;
      expect(spec.entries.single.names, ['print', 'debugPrint']);
    });

    test('rejects unknown target type inside a constraint', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    must_contain:
      not_a_target: [x]
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("Unknown target type 'not_a_target'"),
      );
      // The valid keys (none in this case) still produce a rule with no
      // constraint set, since the bad row is skipped.
      expect(result.ruleSet.rules.single.mustContain, isNull);
    });

    test('parses count with exactly', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: function, names: [main] }
    count:
      target: method_call
      names: [print]
      exactly: 0
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty);
      final c = result.ruleSet.rules.single.count!;
      expect(c.targetType, RuleTargetType.methodCall);
      expect(c.exactly, 0);
      expect(c.min, isNull);
      expect(c.max, isNull);
    });

    test('count.exactly wins over count.min/max with a warning', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: function, names: [main] }
    count:
      target: method_call
      exactly: 1
      min: 5
      max: 10
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('mutually exclusive'),
      );
      final c = result.ruleSet.rules.single.count!;
      expect(c.exactly, 1);
      expect(c.min, isNull);
      expect(c.max, isNull);
    });

    test('count requires at least one of exactly/min/max', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: function, names: [main] }
    count:
      target: method_call
      names: [print]
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("at least one of 'exactly', 'min', or 'max'"),
      );
    });

    test('count.min > count.max is an error', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: function, names: [main] }
    count:
      target: method_call
      min: 5
      max: 1
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('greater than'),
      );
    });

    test('CountSpec.isSatisfiedBy honours bounds and exactly', () {
      final span = SourceFile.fromString('').span(0);
      final exactSpec = CountSpec(
        targetType: RuleTargetType.methodCall,
        names: const [],
        exactly: 2,
        span: span,
      );
      expect(exactSpec.isSatisfiedBy(2), isTrue);
      expect(exactSpec.isSatisfiedBy(1), isFalse);
      expect(exactSpec.isSatisfiedBy(3), isFalse);

      final rangeSpec = CountSpec(
        targetType: RuleTargetType.methodCall,
        names: const [],
        min: 1,
        max: 3,
        span: span,
      );
      expect(rangeSpec.isSatisfiedBy(0), isFalse);
      expect(rangeSpec.isSatisfiedBy(1), isTrue);
      expect(rangeSpec.isSatisfiedBy(3), isTrue);
      expect(rangeSpec.isSatisfiedBy(4), isFalse);
    });

    test('hasConstraints reflects what was parsed', () {
      final none = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    report: { severity: warning, message: m }
''').ruleSet.rules.single;
      expect(none.hasConstraints, isFalse);

      final some = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    must_contain: { method_call: [bar] }
    report: { severity: warning, message: m }
''').ruleSet.rules.single;
      expect(some.hasConstraints, isTrue);
    });
  });
}

ConfigLoadResult parse(String yaml) =>
    parseRuleSet(yamlSource: yaml, sourceFile: '/test.yaml');
