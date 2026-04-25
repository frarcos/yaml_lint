/// One [AnalysisRule] instance, parameterized by a single [RuleConfig].
///
/// **Reference / test-only.** The runtime plugin uses the umbrella
/// [`YamlLintRule`](yaml_lint_rule.dart) — a single registered rule that
/// fans out to every YAML-defined rule via shared diagnostic codes. That
/// shape is forced by `analysis_server_plugin`, which requires every rule
/// to be known at `Plugin.register()` time, before any project has been
/// resolved.
///
/// We keep [DynamicYamlRule] because:
///
///   * the YAML→`LintCode` mapping logic is small, self-contained, and
///     unit-tested here as documentation of the contract;
///   * external embedders that bypass the umbrella (custom plugins,
///     experiments) can still construct it directly.
///
/// Only `target.type == method_call` is wired in this thin variant.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../config/models.dart';

class DynamicYamlRule extends AnalysisRule {
  DynamicYamlRule(this.spec)
    : _code = LintCode(
        spec.report.code,
        spec.report.message,
        severity: diagnosticSeverityFor(spec.report.severity),
      ),
      super(
        name: spec.report.code,
        description: spec.description ?? spec.report.message,
      );

  final RuleConfig spec;
  final LintCode _code;

  @override
  LintCode get diagnosticCode => _code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    switch (spec.target.type) {
      case RuleTargetType.methodCall:
        registry.addMethodInvocation(this, _MethodCallVisitor(this));
      // ignore: no_default_cases
      default:
        break;
    }
  }
}

class _MethodCallVisitor extends SimpleAstVisitor<void> {
  _MethodCallVisitor(this.rule);

  final DynamicYamlRule rule;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final names = rule.spec.target.names;
    final calledName = node.methodName.name;
    if (names.isNotEmpty && !names.contains(calledName)) return;
    rule.reportAtNode(node.methodName);
  }
}

/// Maps yaml_lint's [RuleSeverity] to the analyzer's [DiagnosticSeverity].
///
/// Exposed (rather than private) because the umbrella `YamlLintRule` in
/// `yaml_lint_rule.dart` needs it too — both code paths must produce the
/// same severity for the same YAML rule, otherwise tests against
/// `DynamicYamlRule.diagnosticCode.severity` would silently drift from the
/// production runtime.
DiagnosticSeverity diagnosticSeverityFor(RuleSeverity severity) {
  switch (severity) {
    case RuleSeverity.error:
      return DiagnosticSeverity.ERROR;
    case RuleSeverity.warning:
      return DiagnosticSeverity.WARNING;
    case RuleSeverity.info:
      return DiagnosticSeverity.INFO;
  }
}
