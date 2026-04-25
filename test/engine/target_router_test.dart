/// Verifies that `registerTargetVisitor` dispatches to the right `addX`
/// hooks on [RuleVisitorRegistry] for every [RuleTargetType].
///
/// Spinning up a real analyzer just to check "did the right `addX` get
/// called?" is overkill — instead we hand the router a [_RecordingRegistry]
/// that just remembers the calls. Every visitor goes through the
/// registration code path, which is the contract we care about here. The
/// in-AST behaviour of the visitors themselves is exercised end-to-end by
/// `example/`.
library;

import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/engine/rule_engine.dart';
import 'package:yaml_lint/src/engine/target_router.dart';
import 'package:yaml_lint/src/engine/target_visitors.dart';
import 'package:yaml_lint/src/rules/yaml_lint_rule.dart';

void main() {
  group('registerTargetVisitor', () {
    test('every RuleTargetType registers at least one AST hook', () {
      // Catches the easy regression: someone adds a new value to
      // RuleTargetType but forgets to update the router's switch. With
      // exhaustive switches Dart should error at compile time, but we
      // belt-and-braces it with a runtime assertion too.
      for (final type in RuleTargetType.values) {
        final reg = _RecordingRegistry();
        registerTargetVisitor(
          registry: reg,
          rule: YamlLintRule(),
          engine: _NopEngine(),
          spec: _spec(type),
          code: const LintCode('x', 'x'),
        );
        expect(
          reg.calls,
          isNotEmpty,
          reason: 'No AST hook registered for $type',
        );
      }
    });

    test('per-target hook map is the documented contract', () {
      // Hard-codes the (target → AST-hook(s)) mapping so accidental
      // re-routing (e.g. flipping `widget` from `addInstanceCreationExpression`
      // to `addClassDeclaration`) trips a test instead of silently rerouting
      // every consumer's rules.
      final expectations = <RuleTargetType, List<String>>{
        RuleTargetType.methodCall: ['addMethodInvocation'],
        RuleTargetType.widget: ['addInstanceCreationExpression'],
        RuleTargetType.constructor: ['addInstanceCreationExpression'],
        RuleTargetType.namedArgument: ['addNamedExpression'],
        RuleTargetType.function: [
          'addFunctionDeclaration',
          'addMethodDeclaration',
        ],
        RuleTargetType.classDeclaration: ['addClassDeclaration'],
        RuleTargetType.importDirective: ['addImportDirective'],
        RuleTargetType.annotation: ['addAnnotation'],
        RuleTargetType.variableDeclaration: ['addVariableDeclaration'],
        RuleTargetType.returnStatement: ['addReturnStatement'],
      };

      for (final entry in expectations.entries) {
        final reg = _RecordingRegistry();
        registerTargetVisitor(
          registry: reg,
          rule: YamlLintRule(),
          engine: _NopEngine(),
          spec: _spec(entry.key),
          code: const LintCode('x', 'x'),
        );
        expect(
          reg.calls.map((c) => c.method),
          unorderedEquals(entry.value),
          reason: 'Wrong AST hook(s) for ${entry.key}',
        );
      }
    });

    test('passes a SimpleAstVisitor of the right type to each hook', () {
      // Sanity-check: the visitor we hand the registry should at minimum be
      // a SimpleAstVisitor (otherwise the framework will silently drop it).
      // Spot-check three diverse targets.
      final cases = <RuleTargetType, Type>{
        RuleTargetType.methodCall: MethodCallTargetVisitor,
        RuleTargetType.widget: WidgetTargetVisitor,
        RuleTargetType.annotation: AnnotationTargetVisitor,
      };
      for (final entry in cases.entries) {
        final reg = _RecordingRegistry();
        registerTargetVisitor(
          registry: reg,
          rule: YamlLintRule(),
          engine: _NopEngine(),
          spec: _spec(entry.key),
          code: const LintCode('x', 'x'),
        );
        expect(reg.calls.single.visitor.runtimeType, entry.value);
      }
    });
  });
}

class _RecordingRegistry implements RuleVisitorRegistry {
  final List<_Call> calls = [];

  void _record(String method, AstVisitor visitor) {
    calls.add(_Call(method, visitor));
  }

  @override
  void noSuchMethod(Invocation invocation) {
    final name = _memberName(invocation.memberName);
    if (!name.startsWith('add')) return;
    final args = invocation.positionalArguments;
    final visitor = args.length >= 2 ? args[1] : null;
    if (visitor is AstVisitor) _record(name, visitor);
  }

  static String _memberName(Symbol s) {
    final raw = s.toString();
    final start = raw.indexOf('"') + 1;
    final end = raw.lastIndexOf('"');
    return raw.substring(start, end);
  }
}

class _Call {
  _Call(this.method, this.visitor);
  final String method;
  final AstVisitor visitor;
}

class _NopEngine implements RuleEngine {
  @override
  void onTargetMatched({
    required RuleConfig spec,
    required LintCode code,
    required AstNode reportAt,
    required AstNode scope,
  }) {}
}

RuleConfig _spec(RuleTargetType type) {
  final span = SourceFile.fromString('').span(0);
  return RuleConfig(
    id: 'r_${type.yamlName}',
    target: TargetSpec(type: type, names: const [], span: span),
    report: ReportSpec(
      severity: RuleSeverity.warning,
      code: 'r_${type.yamlName}',
      message: 'msg',
      span: span,
    ),
    span: span,
  );
}
