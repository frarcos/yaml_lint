/// Unit tests for [ConstraintsEngine].
///
/// We use `parseString` (parse-only, no resolution) to build small AST
/// fixtures. That covers every constraint that doesn't require resolved
/// types — everything except `target: widget` and
/// `target: return_statement`'s static-type matching, which are exercised
/// end-to-end by `example/`.
library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/engine/constraints.dart';

void main() {
  group('ConstraintsEngine.shouldReport', () {
    const engine = ConstraintsEngine();
    final span = SourceFile.fromString('').span(0);

    RuleConfig spec({
      ConstraintSpec? mustContain,
      ConstraintSpec? mustNotContain,
      CountSpec? count,
    }) =>
        RuleConfig(
          id: 'r',
          target: TargetSpec(
            type: RuleTargetType.function,
            names: const [],
            span: span,
          ),
          mustContain: mustContain,
          mustNotContain: mustNotContain,
          count: count,
          report: ReportSpec(
            severity: RuleSeverity.warning,
            code: 'r',
            message: 'm',
            span: span,
          ),
          span: span,
        );

    ConstraintSpec constraint(
      RuleTargetType type,
      List<String> names,
    ) =>
        ConstraintSpec(
          entries: [
            ConstraintEntry(targetType: type, names: names, span: span),
          ],
          span: span,
        );

    CountSpec count(
      RuleTargetType type,
      List<String> names, {
      int? min,
      int? max,
      int? exactly,
    }) =>
        CountSpec(
          targetType: type,
          names: names,
          min: min,
          max: max,
          exactly: exactly,
          span: span,
        );

    test('no constraints → always reports (target-only fall-through)', () {
      final scope = parseFunctionBody('void f() { print(1); }');
      expect(
        engine.shouldReport(scope: scope, spec: spec()),
        isTrue,
      );
    });

    test('must_contain: missing call → reports', () {
      final scope = parseFunctionBody('void f() { doNothing(); }');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustContain: constraint(
              RuleTargetType.methodCall,
              ['Analytics.track'],
            ),
          ),
        ),
        isTrue,
      );
    });

    test('must_contain: present call → does NOT report', () {
      final scope = parseFunctionBody(
        'void f() { Analytics.track("x"); }',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustContain: constraint(
              RuleTargetType.methodCall,
              ['Analytics.track'],
            ),
          ),
        ),
        isFalse,
      );
    });

    test('must_contain: bare name and dotted name both match', () {
      // The plan accepts either spelling. `track` (bare) should also
      // match `Analytics.track(...)` so users don't have to know whether
      // the call is qualified.
      final scope = parseFunctionBody(
        'void f() { Analytics.track("x"); }',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustContain: constraint(RuleTargetType.methodCall, ['track']),
          ),
        ),
        isFalse,
      );
    });

    test('must_contain: requires *every* listed name', () {
      // `[a, b]` means both `a` and `b` must appear, not "either is
      // fine". The asymmetry vs `must_not_contain` is intentional and
      // documented in `ConstraintsEngine.shouldReport`.
      final scope = parseFunctionBody(
        'void f() { Analytics.track("x"); }',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustContain: constraint(
              RuleTargetType.methodCall,
              ['Analytics.track', 'Logger.log'],
            ),
          ),
        ),
        isTrue,
      );
    });

    test('must_not_contain: forbidden call present → reports', () {
      final scope = parseFunctionBody('void f() { print(1); }');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustNotContain:
                constraint(RuleTargetType.methodCall, ['print']),
          ),
        ),
        isTrue,
      );
    });

    test('must_not_contain: forbidden call absent → does NOT report', () {
      final scope = parseFunctionBody('void f() { doStuff(); }');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            mustNotContain:
                constraint(RuleTargetType.methodCall, ['print']),
          ),
        ),
        isFalse,
      );
    });

    test('count: exactly satisfied → no report', () {
      final scope = parseFunctionBody(
        'void f() { print(1); }',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            count: count(
              RuleTargetType.methodCall,
              ['print'],
              exactly: 1,
            ),
          ),
        ),
        isFalse,
      );
    });

    test('count: max exceeded → reports', () {
      final scope = parseFunctionBody(
        'void f() { print(1); print(2); print(3); }',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            count: count(
              RuleTargetType.methodCall,
              ['print'],
              max: 2,
            ),
          ),
        ),
        isTrue,
      );
    });

    test('count: min not met → reports', () {
      final scope = parseFunctionBody('void f() {}');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            count: count(
              RuleTargetType.methodCall,
              ['Analytics.track'],
              min: 1,
            ),
          ),
        ),
        isTrue,
      );
    });

    test('count: empty names = wildcard "any of this kind"', () {
      final scope = parseFunctionBody('void f() { a(); b(); c(); }');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: spec(
            count: count(
              RuleTargetType.methodCall,
              const [],
              exactly: 3,
            ),
          ),
        ),
        isFalse,
      );
    });
  });
}

AstNode parseFunctionBody(String source) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final finder = _FirstFunctionFinder();
  result.unit.accept(finder);
  return finder.body!;
}

class _FirstFunctionFinder extends RecursiveAstVisitor<void> {
  FunctionBody? body;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    body ??= node.functionExpression.body;
    super.visitFunctionDeclaration(node);
  }
}
