/// Tests for the lazy-discovery / cache contract of [YamlLintRule].
///
/// We deliberately do **not** spin up a real `RuleContext` here: doing that
/// would require either a full analyzer instance or a hand-rolled mock big
/// enough to dwarf the code under test. Instead we test:
///
///   * the cache + code-union behaviour through the [ProjectConfigResolver]
///     seam, which is the boundary between rule discovery and rule execution;
///   * the YAML→[LintCode] mapping (also covered in
///     `dynamic_yaml_rule_test.dart`).
///
/// End-to-end behaviour against a real Dart AST is verified by `example/`
/// under CI (`dart analyze`), per the same convention as
/// `dynamic_yaml_rule_test.dart`.
library;

import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/rules/yaml_lint_rule.dart';

void main() {
  group('YamlLintRule', () {
    test('discovers and caches per project root', () {
      final loaded = <String>[];
      final resolver = FakeProjectConfigResolver(
        onLoad: (root) {
          loaded.add(root);
          return _result([_spec('no_print', 'no_print')]);
        },
      );
      final rule = YamlLintRule(resolver: resolver);

      rule.debugLoadFor('/proj/a');
      rule.debugLoadFor('/proj/a');
      rule.debugLoadFor('/proj/b');
      rule.debugLoadFor('/proj/a');

      expect(loaded, ['/proj/a', '/proj/b']);
      expect(resolver.loadCount, 2);
    });

    test('reloads when the YAML mtime changes', () {
      var mtime = DateTime.fromMillisecondsSinceEpoch(1);
      final resolver = FakeProjectConfigResolver(
        onLoad: (root) => _result([_spec('no_print', 'no_print')]),
        onMtime: (_) => mtime,
      );
      final rule = YamlLintRule(resolver: resolver);

      rule.debugLoadFor('/proj');
      rule.debugLoadFor('/proj');
      expect(resolver.loadCount, 1);

      mtime = DateTime.fromMillisecondsSinceEpoch(2);
      rule.debugLoadFor('/proj');
      expect(resolver.loadCount, 2);
    });

    test('diagnosticCodes accumulates across project roots', () {
      final byRoot = {
        '/proj/a': _result([_spec('no_print', 'no_print')]),
        '/proj/b': _result([_spec('no_logger', 'no_logger')]),
      };
      final resolver = FakeProjectConfigResolver(
        onLoad: (root) => byRoot[root]!,
      );
      final rule = YamlLintRule(resolver: resolver);

      expect(rule.diagnosticCodes, isEmpty);

      rule.debugLoadFor('/proj/a');
      expect(
        rule.diagnosticCodes.map((c) => c.lowerCaseName),
        ['no_print'],
      );

      rule.debugLoadFor('/proj/b');
      expect(
        rule.diagnosticCodes.map((c) => c.lowerCaseName).toSet(),
        {'no_print', 'no_logger'},
      );
    });

    test(
      'identical code names from two roots are merged into one DiagnosticCode',
      () {
        final byRoot = {
          '/proj/a': _result([_spec('no_print', 'no_print')]),
          '/proj/b': _result([_spec('no_print', 'no_print')]),
        };
        final resolver = FakeProjectConfigResolver(
          onLoad: (root) => byRoot[root]!,
        );
        final rule = YamlLintRule(resolver: resolver);

        rule.debugLoadFor('/proj/a');
        rule.debugLoadFor('/proj/b');

        // Same `code` string from two projects collapses to one entry —
        // see `_uniqueCodeName` in yaml_lint_rule.dart for the rationale.
        expect(rule.diagnosticCodes.length, 1);
      },
    );

    test('handles project roots with no rules gracefully', () {
      final resolver = FakeProjectConfigResolver(
        onLoad: (_) => _result(const []),
      );
      final rule = YamlLintRule(resolver: resolver);

      expect(rule.debugLoadFor('/empty'), 0);
      expect(rule.diagnosticCodes, isEmpty);
    });
  });
}

ConfigLoadResult _result(List<RuleConfig> rules) => ConfigLoadResult(
  ruleSet: RuleSet(version: 1, rules: rules, sourceFile: '/synthetic.yaml'),
  diagnostics: const [],
);

RuleConfig _spec(String id, String code) {
  final span = SourceFile.fromString('').span(0);
  return RuleConfig(
    id: id,
    target: TargetSpec(
      type: RuleTargetType.methodCall,
      names: const ['print'],
      span: span,
    ),
    report: ReportSpec(
      severity: RuleSeverity.warning,
      code: code,
      message: 'msg for $id',
      span: span,
    ),
    span: span,
  );
}
