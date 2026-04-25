/// Parser coverage for `scope:` and the top-level `layers:` block.
library;

import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/config/parser.dart';

void main() {
  group('parseRuleSet (scope:)', () {
    test('parses include + exclude lists', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [print] }
    scope:
      include: ["lib/**/*.dart"]
      exclude: ["lib/generated/**"]
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty,
          reason: result.diagnostics.map((d) => d.message).join('\n'));
      final scope = result.ruleSet.rules.single.scope!;
      expect(scope.include, ['lib/**/*.dart']);
      expect(scope.exclude, ['lib/generated/**']);
    });

    test('eagerly rejects malformed globs', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [print] }
    scope:
      include: ["[bad-glob"]
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('invalid glob'),
      );
    });

    test('warns on unknown sub-keys but keeps the rule', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [print] }
    scope:
      typo: ["lib/**"]
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("Unknown key 'typo'"),
      );
      expect(result.ruleSet.rules, hasLength(1));
    });
  });

  group('parseRuleSet (layers:)', () {
    test('parses a top-level layers map', () {
      final result = parse('''
layers:
  domain:
    paths: ["lib/domain/**"]
  data:
    paths: ["lib/data/**"]

rules:
  - id: r1
    target: { type: method_call, names: [print] }
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty,
          reason: result.diagnostics.map((d) => d.message).join('\n'));
      expect(result.ruleSet.layers.keys.toSet(), {'domain', 'data'});
      expect(result.ruleSet.layers['domain'], ['lib/domain/**']);
    });

    test('reports a malformed layer entry but keeps siblings', () {
      final result = parse('''
layers:
  domain: 'lib/domain/**'
  data:
    paths: ["lib/data/**"]

rules:
  - id: r1
    target: { type: method_call, names: [print] }
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains("must be a map with a 'paths:' list"),
      );
      expect(result.ruleSet.layers.keys, ['data']);
    });
  });
}

ConfigLoadResult parse(String yaml) =>
    parseRuleSet(yamlSource: yaml, sourceFile: '/test.yaml');
