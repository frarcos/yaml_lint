/// One [SimpleAstVisitor] per [RuleTargetType], each implementing the
/// "extract name + decide if this node is a candidate" half of the engine.
///
/// All visitors share the same shape:
///
///   1. Override exactly one `visitX` method (the one matching the
///      target kind they're registered against by `target_router.dart`).
///   2. Compute the candidate name and the report-at / scope nodes
///      from the matched AST node.
///   3. If `target.names` is non-empty and the candidate name isn't in it,
///      bail out (zero diagnostics).
///   4. Otherwise hand control to [RuleEngine.onTargetMatched]; the engine
///      decides whether the rule actually fires based on `when:` /
///      constraints.
///
/// "Name" semantics per target kind:
///
///   | Target               | Name source                                    |
///   |----------------------|------------------------------------------------|
///   | method_call          | `node.methodName.name`                         |
///   | widget               | `node.constructorName.type.name.lexeme` (must extend Flutter `Widget`) |
///   | constructor          | `node.constructorName.type.name.lexeme`        |
///   | named_argument       | `node.name.label.name`                         |
///   | function             | `node.name.lexeme`                             |
///   | class                | `node.name.lexeme`                             |
///   | import               | `node.uri.stringValue` (the URI string)        |
///   | annotation           | `node.name.name`                               |
///   | variable_declaration | `node.name.lexeme`                             |
///   | return_statement     | the static type's element name (or `null`)     |
///
/// A `names: []` block in YAML means "match any node of this kind"; the
/// visitor skips the `names.contains(...)` check in that case.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';

import '../config/models.dart';
import 'rule_engine.dart';

/// Common base: keeps every visitor's constructor + bookkeeping uniform.
abstract class _BaseTargetVisitor extends SimpleAstVisitor<void> {
  _BaseTargetVisitor(this._engine, this._spec, this._code);

  final RuleEngine _engine;
  final RuleConfig _spec;
  final LintCode _code;

  /// Hand off to the engine if [name] passes the `target.names` filter.
  ///
  /// `null` is treated as "no name available" — for declared-name kinds
  /// that's a parse-tree edge (e.g. an unnamed extension); we just ignore
  /// it. For `return_statement` specifically, `null` means "no static
  /// type" and is also ignored.
  void _maybeReport({
    required String? name,
    required AstNode reportAt,
    required AstNode scope,
  }) {
    if (name == null) return;
    final names = _spec.target.names;
    if (names.isNotEmpty && !names.contains(name)) return;
    _engine.onTargetMatched(
      spec: _spec,
      code: _code,
      reportAt: reportAt,
      scope: scope,
    );
  }
}

class MethodCallTargetVisitor extends _BaseTargetVisitor {
  MethodCallTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _maybeReport(
      name: node.methodName.name,
      reportAt: node.methodName,
      // Constraint scope is the full call, so closures in arguments are
      // reachable when constraints traverse.
      scope: node,
    );
  }
}

/// `target: widget` — a constructor invocation whose constructed type is
/// (or extends) Flutter's `Widget` class. Falls back to "any constructor"
/// when type info is missing (e.g. unresolved AST), which is a no-op in
/// practice because [RuleContext] always hands us a resolved unit.
class WidgetTargetVisitor extends _BaseTargetVisitor {
  WidgetTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final namedType = node.constructorName.type;
    final dartType = namedType.type;
    if (dartType is! InterfaceType) return;
    if (!_isFlutterWidget(dartType)) return;
    _maybeReport(
      name: namedType.name.lexeme,
      reportAt: node.constructorName,
      scope: node,
    );
  }

  /// True iff [type] (or any of its supertypes) is named `Widget`.
  ///
  /// This is intentionally a name-based check rather than a library-URI
  /// check: it matches any `Widget` class in the dependency graph, which
  /// covers vanilla Flutter, `flutter_test`, and rebrandings without
  /// hard-coding `package:flutter/...` paths. Collisions with unrelated
  /// `Widget` classes are accepted as a v0.1 trade-off — the alternative
  /// pulls in `package:flutter` as a hard dependency just to compare URIs.
  static bool _isFlutterWidget(InterfaceType type) {
    if (type.element.name == 'Widget') return true;
    for (final supertype in type.allSupertypes) {
      if (supertype.element.name == 'Widget') return true;
    }
    return false;
  }
}

/// `target: constructor` — every `InstanceCreationExpression`, no Widget
/// filter. Useful for rules like "no direct construction of `LegacyService`
/// outside `lib/factories/`".
class ConstructorTargetVisitor extends _BaseTargetVisitor {
  ConstructorTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _maybeReport(
      name: node.constructorName.type.name.lexeme,
      reportAt: node.constructorName,
      scope: node,
    );
  }
}

/// `target: named_argument` — e.g. `onTap: () {}` inside a widget call.
/// The diagnostic anchors on the argument label so the IDE highlights
/// exactly the name; the constraint scope is the argument's expression
/// (typically a closure body) so `must_contain` checks can walk it for
/// inner method calls.
class NamedArgumentTargetVisitor extends _BaseTargetVisitor {
  NamedArgumentTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitNamedExpression(NamedExpression node) {
    _maybeReport(
      name: node.name.label.name,
      reportAt: node.name,
      scope: node.expression,
    );
  }
}

/// `target: function` covers both top-level functions and instance methods.
/// The router registers this visitor for both `addFunctionDeclaration` and
/// `addMethodDeclaration`, so a single class handles both — the dispatcher
/// uses `visitFunctionDeclaration` / `visitMethodDeclaration` polymorphically
/// and the appropriate override fires.
class FunctionTargetVisitor extends _BaseTargetVisitor {
  FunctionTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _maybeReport(
      name: node.name.lexeme,
      reportAt: node,
      scope: node.functionExpression.body,
    );
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _maybeReport(
      name: node.name.lexeme,
      reportAt: node,
      scope: node.body,
    );
  }
}

class ClassTargetVisitor extends _BaseTargetVisitor {
  ClassTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    // analyzer 12.x reorganized class declarations under a `ClassNamePart`
    // node so primary-constructor support could share the structure. The
    // class name is now `namePart.typeName` instead of `name`.
    _maybeReport(
      name: node.namePart.typeName.lexeme,
      reportAt: node,
      scope: node,
    );
  }
}

/// `target: import` — names match against the URI string. Glob/layer
/// matching is handled separately via the `import_from_layer:` predicate
/// inside `when:`; this visitor compares to literal URIs like
/// `package:flutter/material.dart`.
class ImportTargetVisitor extends _BaseTargetVisitor {
  ImportTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitImportDirective(ImportDirective node) {
    _maybeReport(
      name: node.uri.stringValue,
      reportAt: node,
      scope: node,
    );
  }
}

class AnnotationTargetVisitor extends _BaseTargetVisitor {
  AnnotationTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitAnnotation(Annotation node) {
    _maybeReport(
      name: node.name.name,
      reportAt: node,
      scope: node,
    );
  }
}

class VariableDeclarationTargetVisitor extends _BaseTargetVisitor {
  VariableDeclarationTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _maybeReport(
      name: node.name.lexeme,
      reportAt: node,
      scope: node,
    );
  }
}

/// `target: return_statement` matches by the return value's static type.
/// A `names: []` rule fires on every `return` (rare but useful for "no
/// returns in `void main`"-style rules). With names, only returns whose
/// expression has a matching static type fire.
class ReturnStatementTargetVisitor extends _BaseTargetVisitor {
  ReturnStatementTargetVisitor(super.engine, super.spec, super.code);

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    final typeName = expression?.staticType?.element?.name;
    _maybeReport(
      name: typeName ?? '',
      reportAt: node,
      scope: node,
    );
  }
}
