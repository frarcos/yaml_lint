import 'package:test/test.dart';
import 'package:yaml_lint/src/config/loader.dart';
import 'package:yaml_lint/src/config/models.dart';

void main() {
  group('loadProjectConfig', () {
    test('returns empty (no diagnostics) when no config file exists', () {
      final fs = InMemoryFileSystem({});
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.rules, isEmpty);
      expect(result.diagnostics, isEmpty);
    });

    test('prefers lint_rules.yaml over .yaml_lint.yaml', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': _ruleYaml('main_rule'),
        '/proj/.yaml_lint.yaml': _ruleYaml('hidden_rule'),
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.rules.map((r) => r.id), ['main_rule']);
    });

    test('falls back to .yaml_lint.yaml', () {
      final fs = InMemoryFileSystem({
        '/proj/.yaml_lint.yaml': _ruleYaml('hidden_rule'),
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.rules.map((r) => r.id), ['hidden_rule']);
    });

    test('honors overridePath', () {
      final fs = InMemoryFileSystem({
        '/proj/custom/foo.yaml': _ruleYaml('custom_rule'),
      });
      final result = loadProjectConfig(
        projectRoot: '/proj',
        overridePath: 'custom/foo.yaml',
        fs: fs,
      );
      expect(result.ruleSet.rules.single.id, 'custom_rule');
    });

    test('merges includes', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
includes:
  - extra/a.yaml
  - extra/b.yaml
rules:
  - id: root_rule
    target: { type: method_call, names: [foo] }
    report: { severity: info, message: r }
''',
        '/proj/extra/a.yaml': _ruleYaml('rule_a'),
        '/proj/extra/b.yaml': _ruleYaml('rule_b'),
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.rules.map((r) => r.id), [
        'root_rule',
        'rule_a',
        'rule_b',
      ]);
    });

    test('detects include cycles', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
includes: [a.yaml]
rules: []
''',
        '/proj/a.yaml': '''
includes: [b.yaml]
rules: []
''',
        '/proj/b.yaml': '''
includes: [a.yaml]
rules: []
''',
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('Cyclic include'),
      );
    });

    test('reports missing include target', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
includes: [missing.yaml]
rules: []
''',
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('Could not read'),
      );
    });

    test('preserves layers from the entry file', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
layers:
  domain: { paths: ["lib/domain/**"] }
  data:   { paths: ["lib/data/**"] }
rules: []
''',
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.layers.keys, containsAll(['domain', 'data']));
      expect(result.ruleSet.layers['domain'], ['lib/domain/**']);
    });

    test('merges layers across includes; entry file wins on conflicts', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
includes: [extra/a.yaml]
layers:
  domain: { paths: ["lib/domain/**"] }
rules: []
''',
        '/proj/extra/a.yaml': '''
layers:
  domain: { paths: ["IGNORED/**"] }
  data:   { paths: ["lib/data/**"] }
rules: []
''',
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.layers['domain'], ['lib/domain/**']);
      expect(result.ruleSet.layers['data'], ['lib/data/**']);
    });

    test('first-definition-wins on duplicate ids across includes', () {
      final fs = InMemoryFileSystem({
        '/proj/lint_rules.yaml': '''
includes: [other.yaml]
rules:
  - id: shared
    target: { type: method_call, names: [original] }
    report: { severity: info, message: original }
''',
        '/proj/other.yaml': _ruleYaml('shared'),
      });
      final result = loadProjectConfig(projectRoot: '/proj', fs: fs);
      expect(result.ruleSet.rules.single.target.names, ['original']);
      expect(
        result.diagnostics
            .where((d) => d.severity == ConfigDiagnosticSeverity.warning)
            .map((d) => d.message)
            .join(' | '),
        contains('defined in both'),
      );
    });
  });
}

String _ruleYaml(String id) =>
    '''
rules:
  - id: $id
    target:
      type: method_call
      names: [foo]
    report:
      severity: warning
      message: "msg for $id"
''';
