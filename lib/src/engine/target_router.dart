/// Maps a [RuleTargetType] to the right `addX` registration call(s) on
/// [RuleVisitorRegistry] and instantiates the matching visitor from
/// `target_visitors.dart`.
///
/// This is the only place that knows the per-target registration shape, so
/// `yaml_lint_rule.dart` can stay agnostic and other parts of the engine
/// (constraints, conditions) can be added without touching the wiring.
///
/// Note that two of the ten target kinds register against multiple AST node
/// types:
///
///   * `RuleTargetType.function` registers against both
///     `addFunctionDeclaration` (top-level + local functions) and
///     `addMethodDeclaration` (instance methods on classes/mixins/extensions).
///     A user writing `target: function names: [build]` reasonably expects
///     `Widget build(...)` methods to match too — splitting "function" and
///     "method" in the YAML DSL would surprise more users than the join.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/error/error.dart';

import '../config/models.dart';
import 'rule_engine.dart';
import 'target_visitors.dart';

/// Single entry point: hook the right visitor(s) for [spec] into [registry].
void registerTargetVisitor({
  required RuleVisitorRegistry registry,
  required AbstractAnalysisRule rule,
  required RuleEngine engine,
  required RuleConfig spec,
  required LintCode code,
}) {
  switch (spec.target.type) {
    case RuleTargetType.methodCall:
      registry.addMethodInvocation(
        rule,
        MethodCallTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.widget:
      registry.addInstanceCreationExpression(
        rule,
        WidgetTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.constructor:
      registry.addInstanceCreationExpression(
        rule,
        ConstructorTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.namedArgument:
      registry.addNamedExpression(
        rule,
        NamedArgumentTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.function:
      // Same visitor instance handles both — `SimpleAstVisitor`
      // dispatches polymorphically based on which `add*` hook fires.
      final visitor = FunctionTargetVisitor(engine, spec, code);
      registry.addFunctionDeclaration(rule, visitor);
      registry.addMethodDeclaration(rule, visitor);
    case RuleTargetType.classDeclaration:
      registry.addClassDeclaration(
        rule,
        ClassTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.importDirective:
      registry.addImportDirective(
        rule,
        ImportTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.annotation:
      registry.addAnnotation(
        rule,
        AnnotationTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.variableDeclaration:
      registry.addVariableDeclaration(
        rule,
        VariableDeclarationTargetVisitor(engine, spec, code),
      );
    case RuleTargetType.returnStatement:
      registry.addReturnStatement(
        rule,
        ReturnStatementTargetVisitor(engine, spec, code),
      );
  }
}
