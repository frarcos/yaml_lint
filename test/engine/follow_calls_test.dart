/// Integration-flavoured tests for the `follow_calls:` constraint
/// extension.
///
/// `parseString` doesn't resolve identifiers, so the engine's
/// `methodName.element` would be `null`. We need a *resolved* unit
/// — `package:analyzer` provides `resolveFile` on a real path, so each
/// test writes a temporary `.dart` file inside its own per-test temp
/// directory and then asks the analyzer to resolve it.
///
/// The fixtures stay tiny on purpose: every test focuses on one axis
/// of the recursion behaviour (depth limit, cycle guard, tear-off
/// expansion, …) so failures point straight at the responsible code
/// path in `constraints.dart`.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/engine/constraints.dart';

void main() {
  group('follow_calls (resolved AST)', () {
    const engine = ConstraintsEngine();
    final span = SourceFile.fromString('').span(0);

    /// Builds a [RuleConfig] focused on the recursion semantics: a
    /// `must_contain: method_call: [Analytics.track]` constraint with
    /// optional follow_calls.
    RuleConfig mustContainTrack({FollowCallsSpec? followCalls}) => RuleConfig(
      id: 'r',
      target: TargetSpec(
        type: RuleTargetType.namedArgument,
        names: const ['onTap'],
        span: span,
      ),
      mustContain: ConstraintSpec(
        entries: [
          ConstraintEntry(
            targetType: RuleTargetType.methodCall,
            names: const ['Analytics.track'],
            span: span,
          ),
        ],
        span: span,
      ),
      followCalls: followCalls,
      report: ReportSpec(
        severity: RuleSeverity.warning,
        code: 'r',
        message: 'm',
        span: span,
      ),
      span: span,
    );

    FollowCallsSpec follow(int depth, {bool samePackageOnly = true}) =>
        FollowCallsSpec(
          maxDepth: depth,
          samePackageOnly: samePackageOnly,
          span: span,
        );

    test(
      'depth 0 (no follow): closure that delegates to a helper trips '
      'must_contain',
      () async {
        final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void trackTap() { Analytics.track('tap'); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { trackTap(); });
}
''');

        final scope = fixture.findNamedArgScope('onTap');
        final reports = engine.shouldReport(
          scope: scope,
          spec: mustContainTrack(),
          context: fixture.context,
        );
        expect(
          reports,
          isTrue,
          reason: 'without follow_calls, the closure body has no '
              'Analytics.track call so the constraint trips',
        );
      },
    );

    test(
      'depth 1: same closure now satisfies must_contain via trackTap',
      () async {
        final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void trackTap() { Analytics.track('tap'); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { trackTap(); });
}
''');

        final scope = fixture.findNamedArgScope('onTap');
        final reports = engine.shouldReport(
          scope: scope,
          spec: mustContainTrack(followCalls: follow(1)),
          context: fixture.context,
        );
        expect(
          reports,
          isFalse,
          reason: 'depth 1 should follow into trackTap()',
        );
      },
    );

    test('depth 1 is not enough when the call is one level deeper', () async {
      final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void doInner() { Analytics.track('inner'); }
void doOuter() { doInner(); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { doOuter(); });
}
''');

      final scope = fixture.findNamedArgScope('onTap');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: mustContainTrack(followCalls: follow(1)),
          context: fixture.context,
        ),
        isTrue,
        reason: 'closure → doOuter is depth 1, doOuter → doInner is depth '
            '2 — the track call lives at depth 2',
      );
      expect(
        engine.shouldReport(
          scope: scope,
          spec: mustContainTrack(followCalls: follow(2)),
          context: fixture.context,
        ),
        isFalse,
        reason: 'depth 2 reaches doInner and finds Analytics.track',
      );
    });

    test('mutual recursion does not loop', () async {
      // a() and b() call each other; neither calls Analytics.track.
      // The cycle guard must terminate, and must_contain must report.
      final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void a() { b(); }
void b() { a(); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { a(); });
}
''');

      final scope = fixture.findNamedArgScope('onTap');
      expect(
        engine.shouldReport(
          scope: scope,
          spec: mustContainTrack(followCalls: follow(10)),
          context: fixture.context,
        ),
        isTrue,
        reason: 'a/b are mutually recursive and never call Analytics.track',
      );
    });

    test(
      'tear-off as the named argument is expanded to the referenced body',
      () async {
        final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void trackTap() { Analytics.track('tap'); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: trackTap);
}
''');

        final scope = fixture.findNamedArgScope('onTap');
        // Without follow_calls, the scope is just the SimpleIdentifier
        // `trackTap`, which has no Analytics.track call, so the constraint
        // would always trip. Asserting the bare-scope behaviour first
        // pins down the regression check.
        expect(
          engine.shouldReport(
            scope: scope,
            spec: mustContainTrack(),
            context: fixture.context,
          ),
          isTrue,
        );
        // With follow_calls, the engine substitutes trackTap's body
        // as the level-0 scope and finds Analytics.track immediately.
        expect(
          engine.shouldReport(
            scope: scope,
            spec: mustContainTrack(followCalls: follow(1)),
            context: fixture.context,
          ),
          isFalse,
        );
      },
    );

    test(
      'cross-library callee is silently skipped (engine limitation)',
      () async {
        // print() lives in dart:core, so it's not in our `allUnits` map.
        // The engine should treat it as "no body to descend into" and
        // not throw.
        final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { print('tap'); });
}
''');

        final scope = fixture.findNamedArgScope('onTap');
        expect(
          engine.shouldReport(
            scope: scope,
            spec: mustContainTrack(followCalls: follow(5)),
            context: fixture.context,
          ),
          isTrue,
          reason: 'print is reachable but not followable; constraint trips',
        );
      },
    );

    test('count constraint: follow_calls widens the count window', () async {
      final fixture = await _resolveFixture('''
class Analytics {
  static void track(String name) {}
}

void trackTap() { Analytics.track('a'); Analytics.track('b'); }

void run({required void Function() onTap}) {}

void main() {
  run(onTap: () { trackTap(); });
}
''');

      final scope = fixture.findNamedArgScope('onTap');
      final spec = RuleConfig(
        id: 'r',
        target: TargetSpec(
          type: RuleTargetType.namedArgument,
          names: const ['onTap'],
          span: span,
        ),
        count: CountSpec(
          targetType: RuleTargetType.methodCall,
          names: const ['Analytics.track'],
          min: 2,
          span: span,
        ),
        followCalls: follow(1),
        report: ReportSpec(
          severity: RuleSeverity.warning,
          code: 'r',
          message: 'm',
          span: span,
        ),
        span: span,
      );

      expect(
        engine.shouldReport(scope: scope, spec: spec, context: fixture.context),
        isFalse,
        reason: 'follow_calls 1 reaches trackTap which calls track twice — '
            'count.min: 2 is satisfied',
      );
    });
  });
}

/// Resolves [source] as a tiny package on disk, returning the helpers
/// the tests need. A fresh temp directory per call keeps each test
/// hermetic.
Future<_Fixture> _resolveFixture(String source) async {
  final tmp = await Directory.systemTemp.createTemp('yaml_lint_fc_');
  final lib = Directory('${tmp.path}/lib')..createSync(recursive: true);
  File('${tmp.path}/pubspec.yaml').writeAsStringSync(
    'name: yaml_lint_fc_fixture\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n',
  );
  final dartFile = File('${lib.path}/main.dart');
  dartFile.writeAsStringSync(source);

  final result = await resolveFile(path: dartFile.path);
  if (result is! ResolvedUnitResult) {
    throw StateError('failed to resolve fixture: $result');
  }

  // Drain the temp dir at the end of the test run. We schedule it via
  // addTearDown so even failing tests clean up.
  addTearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  return _Fixture(
    unit: result.unit,
    context: EngineContext(allUnits: [result.unit], projectRoot: tmp.path),
  );
}

class _Fixture {
  _Fixture({required this.unit, required this.context});

  final CompilationUnit unit;
  final EngineContext context;

  /// Returns the [Expression] passed as the named argument [name] to
  /// the *first* method invocation that uses it. Mirrors what
  /// `NamedArgumentTargetVisitor` hands to the engine at runtime.
  Expression findNamedArgScope(String name) {
    final finder = _NamedArgFinder(name);
    unit.accept(finder);
    final found = finder.found;
    if (found == null) {
      throw StateError('Fixture has no named argument named "$name"');
    }
    return found;
  }
}

class _NamedArgFinder extends RecursiveAstVisitor<void> {
  _NamedArgFinder(this.name);
  final String name;
  Expression? found;

  @override
  void visitNamedExpression(NamedExpression node) {
    if (found == null && node.name.label.name == name) {
      found = node.expression;
    }
    super.visitNamedExpression(node);
  }
}
