/// Unit tests for the leaf predicates and the `Condition` evaluator.
///
/// We use `parseString` (parse-only) to build small AST fixtures. That
/// covers every predicate that doesn't require resolved types —
/// `inside_widget`'s "extends Widget" supertype check is intentionally
/// name-based so it works without resolution and is exercised here too.
library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/engine/conditions.dart';
import 'package:yaml_lint/src/engine/predicates.dart';

void main() {
  const evaluator = ConditionEvaluator();
  final span = SourceFile.fromString('').span(0);

  bool eval(Condition c, AstNode node, {String filePath = '/lib/x.dart'}) =>
      evaluator.evaluate(
        c,
        ConditionContext(matchedNode: node, filePath: filePath),
      );

  // Always-true / always-false leaves we can stand in for boolean tests.
  final tCond = FilePathCondition(startsWith: '/lib', span: span);
  final fCond = FilePathCondition(startsWith: '/__nope__', span: span);

  group('boolean composition', () {
    final node = _firstStatement('void f() { x(); }');

    test('all: empty = true', () {
      expect(eval(AllCondition(children: const [], span: span), node), isTrue);
    });

    test('all: short-circuits on the first false', () {
      expect(
        eval(
          AllCondition(children: [tCond, fCond, tCond], span: span),
          node,
        ),
        isFalse,
      );
    });

    test('any: empty = false', () {
      expect(eval(AnyCondition(children: const [], span: span), node), isFalse);
    });

    test('any: returns true on the first true', () {
      expect(
        eval(
          AnyCondition(children: [fCond, fCond, tCond], span: span),
          node,
        ),
        isTrue,
      );
    });

    test('not: inverts', () {
      expect(eval(NotCondition(child: tCond, span: span), node), isFalse);
      expect(eval(NotCondition(child: fCond, span: span), node), isTrue);
    });
  });

  group('Predicates.insideWidget', () {
    // `new Container(...)` forces the parser to produce an
    // `InstanceCreationExpression` even without resolution; bare
    // `Container(...)` would be ambiguous and parsed as a
    // `MethodInvocation`. Without a Widget supertype to check (no
    // resolution) the predicate falls through to a name match, which is
    // exactly the path we want to cover here. End-to-end resolution is
    // exercised by `example/`.
    test('matches when ancestor constructs the widget', () {
      final node = _firstMethodCall('''
void f() {
  new Container(child: print(1));
}
''');
      expect(Predicates.insideWidget(node, 'Container'), isTrue);
    });

    test('does not match when no widget ancestor exists', () {
      final node = _firstMethodCall('void f() { print(1); }');
      expect(Predicates.insideWidget(node, 'Container'), isFalse);
    });
  });

  group('Predicates.insideClassAnnotatedWith', () {
    test('matches when the enclosing class has the annotation', () {
      final node = _firstMethodCall('''
class Riverpod { const Riverpod(); }
@Riverpod()
class MyState {
  void m() { compute(); }
}
''');
      expect(
        Predicates.insideClassAnnotatedWith(node, 'Riverpod'),
        isTrue,
      );
    });

    test('does not match without the annotation', () {
      final node = _firstMethodCall('''
class MyState { void m() { compute(); } }
''');
      expect(
        Predicates.insideClassAnnotatedWith(node, 'Riverpod'),
        isFalse,
      );
    });
  });

  group('Predicates.fileMatches', () {
    test('matches simple globs', () {
      // `**` matches zero or more *full path segments*, so a top-level
      // `lib/x.dart` needs `lib/*.dart` (no `**` segment in front of
      // `*.dart`). `lib/**/*.dart` requires at least one intermediate
      // directory, which we exercise separately below.
      expect(Predicates.fileMatches('lib/x.dart', 'lib/*.dart'), isTrue);
      expect(
        Predicates.fileMatches('lib/feature/x.dart', 'lib/**/*.dart'),
        isTrue,
      );
      expect(
        Predicates.fileMatches('test/x.dart', 'lib/**/*.dart'),
        isFalse,
      );
    });

    test('returns false on a malformed glob instead of throwing', () {
      expect(Predicates.fileMatches('lib/x.dart', '['), isFalse);
    });
  });

  group('Predicates.filePath', () {
    const path = '/Users/me/proj/lib/features/auth/auth_page.dart';

    test('startsWith / endsWith / contains', () {
      expect(Predicates.filePath(path, startsWith: '/Users/me'), isTrue);
      expect(Predicates.filePath(path, endsWith: '_page.dart'), isTrue);
      expect(Predicates.filePath(path, contains: 'features/auth'), isTrue);
      expect(Predicates.filePath(path, startsWith: '/nope'), isFalse);
    });

    test('regex', () {
      expect(Predicates.filePath(path, regex: r'auth_.*\.dart$'), isTrue);
      expect(Predicates.filePath(path, regex: r'^/var/'), isFalse);
    });

    test('multiple sub-fields combine as AND', () {
      expect(
        Predicates.filePath(path, startsWith: '/Users', endsWith: '.dart'),
        isTrue,
      );
      expect(
        Predicates.filePath(path, startsWith: '/Users', endsWith: '.txt'),
        isFalse,
      );
    });
  });

  group('Predicates.callbackBodyContains', () {
    test('finds a bare-name call in the enclosing body', () {
      final node = _firstMethodCall('''
void f() {
  log('hello');
}
''');
      expect(
        Predicates.callbackBodyContains(node, ['log']),
        isTrue,
      );
    });

    test('finds a qualified call', () {
      final node = _firstMethodCall('''
void f() {
  Analytics.track('e');
}
''');
      expect(
        Predicates.callbackBodyContains(node, ['Analytics.track']),
        isTrue,
      );
      // Bare name also matches.
      expect(
        Predicates.callbackBodyContains(node, ['track']),
        isTrue,
      );
    });

    test('returns false when no body matches', () {
      final node = _firstMethodCall('void f() { other(); }');
      expect(
        Predicates.callbackBodyContains(node, ['log']),
        isFalse,
      );
    });
  });

  group('Predicates.classNameMatches / methodNameStartsWith', () {
    test('class_name_matches walks up to ClassDeclaration', () {
      final node = _firstMethodCall('''
class HomeState { void m() { compute(); } }
''');
      expect(Predicates.classNameMatches(node, r'.*State$'), isTrue);
      expect(Predicates.classNameMatches(node, r'^Foo'), isFalse);
    });

    test('method_name_starts_with walks up to MethodDeclaration', () {
      final node = _firstMethodCall('''
class C { void buildHeader() { compute(); } }
''');
      expect(Predicates.methodNameStartsWith(node, 'build'), isTrue);
      expect(Predicates.methodNameStartsWith(node, 'render'), isFalse);
    });

    test('method_name_starts_with also matches top-level functions', () {
      final node = _firstMethodCall('void buildPage() { compute(); }');
      expect(Predicates.methodNameStartsWith(node, 'build'), isTrue);
    });
  });

  group('Predicates.importFromLayer', () {
    test('returns false when layers map is null', () {
      final node = _firstMethodCall('''
import 'package:domain/x.dart';
void f() { compute(); }
''');
      expect(
        Predicates.importFromLayer(node, '/lib/x.dart', 'domain', null),
        isFalse,
      );
    });

    test('matches when an import URI matches a glob in the layer', () {
      final node = _firstMethodCall('''
import 'package:domain/x.dart';
void f() { compute(); }
''');
      expect(
        Predicates.importFromLayer(
          node,
          '/lib/x.dart',
          'domain',
          {'domain': const ['package:domain/**']},
        ),
        isTrue,
      );
    });

    test('returns false when no import matches the glob', () {
      final node = _firstMethodCall('''
import 'package:other/x.dart';
void f() { compute(); }
''');
      expect(
        Predicates.importFromLayer(
          node,
          '/lib/x.dart',
          'domain',
          {'domain': const ['package:domain/**']},
        ),
        isFalse,
      );
    });
  });
}

AstNode _firstStatement(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _FirstStatementFinder();
  unit.accept(finder);
  return finder.statement!;
}

AstNode _firstMethodCall(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final finder = _FirstMethodCallFinder();
  unit.accept(finder);
  return finder.call!;
}

class _FirstStatementFinder extends RecursiveAstVisitor<void> {
  Statement? statement;

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    statement ??= node;
    super.visitExpressionStatement(node);
  }
}

class _FirstMethodCallFinder extends RecursiveAstVisitor<void> {
  MethodInvocation? call;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    call ??= node;
    super.visitMethodInvocation(node);
  }
}
