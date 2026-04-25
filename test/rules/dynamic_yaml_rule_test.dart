import 'package:analyzer/error/error.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/rules/dynamic_yaml_rule.dart';

/// A note on coverage: behavioural tests against a real Dart AST run
/// through the rule engine and `target_visitors.dart` and are exercised by
/// the engine-level tests. Here we cover construction and the
/// YAML→diagnostic-code mapping; the end-to-end behaviour is verified by
/// `example/` under CI.
void main() {
  group('DynamicYamlRule', () {
    test('maps YAML report → LintCode', () {
      final rule = DynamicYamlRule(
        _spec(
          id: 'analytics_required',
          severity: RuleSeverity.error,
          message: 'Missing Analytics.track',
        ),
      );

      expect(rule.name, 'analytics_required');
      expect(rule.description, 'Missing Analytics.track');
      expect(rule.diagnosticCode.lowerCaseName, 'analytics_required');
      expect(rule.diagnosticCode.problemMessage, 'Missing Analytics.track');
      expect(rule.diagnosticCode.severity, DiagnosticSeverity.ERROR);
    });

    test('uses report.code when distinct from id', () {
      final rule = DynamicYamlRule(
        _spec(id: 'no_print', codeOverride: 'stop_printing'),
      );
      expect(rule.diagnosticCode.lowerCaseName, 'stop_printing');
      // `name` on AnalysisRule is what the analysis server uses for
      // `// ignore: yaml_lint/<name>` resolution.
      expect(rule.name, 'stop_printing');
    });

    test('description falls back to message when not provided', () {
      final rule = DynamicYamlRule(_spec(id: 'foo', message: 'fallback'));
      expect(rule.description, 'fallback');
    });

    test('description uses spec.description when provided', () {
      final rule = DynamicYamlRule(
        _spec(id: 'foo', message: 'm', description: 'long form'),
      );
      expect(rule.description, 'long form');
    });

    test('maps each RuleSeverity to the right DiagnosticSeverity', () {
      expect(
        DynamicYamlRule(
          _spec(severity: RuleSeverity.error),
        ).diagnosticCode.severity,
        DiagnosticSeverity.ERROR,
      );
      expect(
        DynamicYamlRule(
          _spec(severity: RuleSeverity.warning),
        ).diagnosticCode.severity,
        DiagnosticSeverity.WARNING,
      );
      expect(
        DynamicYamlRule(
          _spec(severity: RuleSeverity.info),
        ).diagnosticCode.severity,
        DiagnosticSeverity.INFO,
      );
    });
  });
}

RuleConfig _spec({
  String id = 'r',
  String? description,
  RuleSeverity severity = RuleSeverity.warning,
  String message = 'msg',
  String? codeOverride,
}) {
  final span = SourceFile.fromString('').span(0);
  return RuleConfig(
    id: id,
    description: description,
    target: TargetSpec(
      type: RuleTargetType.methodCall,
      names: const ['print'],
      span: span,
    ),
    report: ReportSpec(
      severity: severity,
      code: codeOverride ?? id,
      message: message,
      span: span,
    ),
    span: span,
  );
}
