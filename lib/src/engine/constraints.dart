/// Constraint engine: implements `must_contain`, `must_not_contain`, and
/// `count` against a Dart AST scope, with optional `follow_calls`
/// recursive descent into invoked function/method bodies.
///
/// ## Where this fits
///
/// Once `target_visitors.dart` decides "this AST node matches the rule's
/// target type and name", the engine still has to decide whether the rule
/// actually fires. The constraint stage answers that, via
/// [ConstraintsEngine.shouldReport]:
///
/// ```text
/// target match → constraints (this file) → diagnostic
/// ```
///
/// ## Scope
///
/// The "scope" passed in is the matched AST node's natural inner region
/// (computed by the target visitor). For example:
///
///   * `target: method_call` → the whole `MethodInvocation` node, so a
///     callback passed as an argument is reachable.
///   * `target: named_argument` → the argument's `expression` (typically
///     a closure body, but possibly a tear-off identifier — see below).
///   * `target: function` → the function body.
///
/// ## Name matching
///
/// Names in YAML can be either the bare identifier (`track`) or a dotted
/// form (`Analytics.track`). The matchers below accept both.
///
/// ## follow_calls
///
/// When a rule sets `follow_calls:`, the engine after walking [scope]
/// also descends into the bodies of callees invoked from [scope], up to
/// `max_depth` levels. Cycles are guarded with a [Set<Element>]. Callees
/// that don't have a body reachable through [RuleContext.allUnits]
/// (cross-library references, dart:core, package:flutter, etc.) are
/// silently skipped — the parser already documents this limitation.
///
/// Tear-off-as-scope is also handled: if the scope itself is a bare
/// `SimpleIdentifier` / `PrefixedIdentifier` resolving to an
/// [ExecutableElement] (e.g. `onTap: trackTap`), the engine substitutes
/// the body of that declaration as the "level 0" walk.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../config/models.dart';

/// Per-analysis context used by the engine to resolve callees back to
/// their declaring AST when `follow_calls:` is in effect.
///
/// The body lookup is built lazily on first access — rules without
/// `follow_calls` pay nothing.
class EngineContext {
  EngineContext({
    required this.allUnits,
    this.projectRoot,
  });

  /// All compilation units making up the library currently under analysis
  /// (main file + parts), as exposed by `RuleContext.allUnits`.
  final List<CompilationUnit> allUnits;

  /// Absolute path to the consumer project's root, used as a defensive
  /// "same-package" guard. Optional — when null, the body map alone is
  /// the gate.
  final String? projectRoot;

  Map<Element, AstNode>? _bodyByElement;

  /// Lazily-built `Element → FunctionBody` lookup table. Includes every
  /// top-level [FunctionDeclaration], every [MethodDeclaration], and
  /// every [ConstructorDeclaration] reachable through [allUnits].
  Map<Element, AstNode> get bodyByElement =>
      _bodyByElement ??= _buildBodyByElement(allUnits);
}

Map<Element, AstNode> _buildBodyByElement(List<CompilationUnit> units) {
  final map = <Element, AstNode>{};
  final collector = _DeclarationCollector(map);
  for (final unit in units) {
    unit.accept(collector);
  }
  return map;
}

class _DeclarationCollector extends RecursiveAstVisitor<void> {
  _DeclarationCollector(this.map);
  final Map<Element, AstNode> map;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final el = node.declaredFragment?.element;
    if (el != null) {
      map[el.baseElement] = node.functionExpression.body;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final el = node.declaredFragment?.element;
    if (el != null) {
      map[el.baseElement] = node.body;
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    final el = node.declaredFragment?.element;
    if (el != null) {
      map[el.baseElement] = node.body;
    }
    super.visitConstructorDeclaration(node);
  }
}

/// Stateless façade. Lives in a class so callers can pass it as a value
/// (e.g. for test seams) without having to mock free functions.
class ConstraintsEngine {
  const ConstraintsEngine();

  /// Returns `true` iff the rule should report at this match site.
  ///
  /// Decision matrix (with follow_calls disabled):
  ///
  /// | spec.hasConstraints | mustContain    | mustNotContain | count        | result |
  /// |---------------------|----------------|----------------|--------------|--------|
  /// | false               | -              | -              | -            | true (no-constraints fall-through) |
  /// | true                | one missing    | -              | -            | true |
  /// | true                | -              | any present    | -            | true |
  /// | true                | -              | -              | out of range | true |
  /// | true                | all present    | none present   | in range     | false |
  ///
  /// When [spec.followCalls] is set, "present in scope" is widened to
  /// "present in scope OR transitively reachable through up to N
  /// invoked bodies".
  bool shouldReport({
    required AstNode scope,
    required RuleConfig spec,
    EngineContext? context,
  }) {
    if (!spec.hasConstraints) return true;

    final follow = spec.followCalls;
    final ctx = follow != null ? context : null;

    final mustContain = spec.mustContain;
    if (mustContain != null) {
      for (final entry in mustContain.entries) {
        // Each *individual* name is required: the scope must contain at
        // least one occurrence per name. (`{ method_call: [a, b] }` means
        // "both `a` and `b` must appear", not "either is fine".)
        for (final name in entry.names) {
          final any = _hasAny(
            scope: scope,
            type: entry.targetType,
            names: [name],
            followCalls: follow,
            context: ctx,
          );
          if (!any) return true;
        }
      }
    }

    final mustNotContain = spec.mustNotContain;
    if (mustNotContain != null) {
      for (final entry in mustNotContain.entries) {
        // Any forbidden name appearing once → violation.
        if (_hasAny(
          scope: scope,
          type: entry.targetType,
          names: entry.names,
          followCalls: follow,
          context: ctx,
        )) {
          return true;
        }
      }
    }

    final count = spec.count;
    if (count != null) {
      final c = _countMatches(
        scope: scope,
        type: count.targetType,
        names: count.names,
        followCalls: follow,
        context: ctx,
      );
      if (!count.isSatisfiedBy(c)) return true;
    }

    return false;
  }

  static bool _hasAny({
    required AstNode scope,
    required RuleTargetType type,
    required List<String> names,
    FollowCallsSpec? followCalls,
    EngineContext? context,
  }) {
    final visitor = _MatchVisitor(
      type: type,
      names: names,
      stopOnFirst: true,
      followCalls: followCalls,
      context: context,
    );
    _runWithFollow(scope: scope, visitor: visitor, followCalls: followCalls);
    return visitor.matchCount > 0;
  }

  static int _countMatches({
    required AstNode scope,
    required RuleTargetType type,
    required List<String> names,
    FollowCallsSpec? followCalls,
    EngineContext? context,
  }) {
    final visitor = _MatchVisitor(
      type: type,
      names: names,
      followCalls: followCalls,
      context: context,
    );
    _runWithFollow(scope: scope, visitor: visitor, followCalls: followCalls);
    return visitor.matchCount;
  }

  /// Walks [scope], then BFSes through any bodies the visitor enqueued
  /// while walking, up to [followCalls.maxDepth] levels deep.
  ///
  /// When [scope] is itself a tear-off identifier (e.g. `onTap: trackTap`)
  /// and `follow_calls` is enabled, the body of the referenced declaration
  /// is used as the level-0 walk instead of the identifier node — a bare
  /// `SimpleIdentifier` has no children that any constraint could hit, so
  /// without this expansion, tear-off callbacks would always trip
  /// `must_contain`.
  static void _runWithFollow({
    required AstNode scope,
    required _MatchVisitor visitor,
    FollowCallsSpec? followCalls,
  }) {
    final tearOff = followCalls != null
        ? _resolveTearOffScope(scope, visitor.context)
        : null;
    if (tearOff != null) {
      visitor.visited.add(tearOff.key.baseElement);
      tearOff.value.accept(visitor);
    } else {
      scope.accept(visitor);
    }

    if (followCalls == null) return;
    if (visitor.stopOnFirst && visitor.matchCount > 0) return;

    var depth = 0;
    while (depth < followCalls.maxDepth && visitor.pendingBodies.isNotEmpty) {
      final next = visitor.pendingBodies.toList(growable: false);
      visitor.pendingBodies.clear();
      for (final body in next) {
        body.accept(visitor);
        if (visitor.stopOnFirst && visitor.matchCount > 0) return;
      }
      depth++;
    }
  }

  /// If [scope] is a bare callable reference whose declaration body is
  /// reachable, returns `(element, body)`. Otherwise `null`.
  static MapEntry<Element, AstNode>? _resolveTearOffScope(
    AstNode scope,
    EngineContext? context,
  ) {
    if (context == null) return null;
    Element? el;
    if (scope is SimpleIdentifier) {
      el = scope.element;
    } else if (scope is PrefixedIdentifier) {
      el = scope.identifier.element;
    } else if (scope is PropertyAccess) {
      el = scope.propertyName.element;
    } else if (scope is FunctionReference) {
      final fn = scope.function;
      if (fn is SimpleIdentifier) {
        el = fn.element;
      } else if (fn is PrefixedIdentifier) {
        el = fn.identifier.element;
      }
    }
    if (el == null) return null;
    if (el is! ExecutableElement) return null;
    final base = el.baseElement;
    final body = context.bodyByElement[base];
    if (body == null) return null;
    return MapEntry(base, body);
  }
}

/// Walks a subtree counting AST occurrences that match a given target
/// type and (optional) name set. Mirrors the per-target name extraction
/// in `target_visitors.dart` but is decoupled from it: this visitor does
/// not report diagnostics, it just answers "does this exist?" / "how
/// many?".
///
/// When [followCalls] and [context] are both set, the visitor also
/// records a *queue* of [pendingBodies] — each entry is the body of a
/// declaration invoked from the walked subtree that the engine has not
/// yet descended into. The engine drains this queue level by level,
/// guarded by [visited] to break recursion cycles.
class _MatchVisitor extends RecursiveAstVisitor<void> {
  _MatchVisitor({
    required this.type,
    required this.names,
    this.stopOnFirst = false,
    this.followCalls,
    this.context,
  });

  final RuleTargetType type;
  final List<String> names;

  /// When true, the visitor short-circuits after the first match by
  /// no-op'ing all subsequent visit methods (cheap "any" check).
  final bool stopOnFirst;

  final FollowCallsSpec? followCalls;
  final EngineContext? context;

  int matchCount = 0;

  /// Bodies queued for the next BFS pass. Each body is appended at most
  /// once thanks to [visited].
  final List<AstNode> pendingBodies = [];

  /// Element-level cycle guard. Indexed by [Element.baseElement] so
  /// fragmentary distinctions don't accidentally bypass the check.
  final Set<Element> visited = {};

  bool get _shouldStop => stopOnFirst && matchCount > 0;
  bool get _followingEnabled => followCalls != null && context != null;

  bool _matchesName(String? candidate, [String? qualified]) {
    if (names.isEmpty) return true; // wildcard — any node of [type] matches
    if (candidate != null && names.contains(candidate)) return true;
    if (qualified != null && names.contains(qualified)) return true;
    return false;
  }

  /// Records [element]'s body for a future BFS pass, when:
  ///
  ///   * follow-calls is on,
  ///   * the element resolves to an [ExecutableElement] we haven't seen,
  ///   * and the body is reachable through [EngineContext.bodyByElement]
  ///     (i.e. the element lives in the current library; cross-library
  ///     callees are silently skipped — see the library doc-comment).
  void _enqueueIfFollowable(Element? element) {
    if (!_followingEnabled) return;
    if (element == null) return;
    if (element is! ExecutableElement) return;
    final base = element.baseElement;
    if (visited.contains(base)) return;
    final body = context!.bodyByElement[base];
    if (body == null) return;

    // Defensive same-package guard. The map is built only from the
    // current library's units, so any element in it is by definition
    // in the current package; this check is mostly a safety net for
    // a future world where allUnits widens to include cross-library
    // material.
    if (followCalls!.samePackageOnly) {
      final root = context!.projectRoot;
      if (root != null) {
        final src = base.firstFragment.libraryFragment.source.fullName;
        if (!src.startsWith(root)) return;
      }
    }

    visited.add(base);
    pendingBodies.add(body);
  }

  // method_call ----------------------------------------------------------
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.methodCall) {
      final method = node.methodName.name;
      // Build "X.method" if the call has a target (e.g. Analytics.track).
      // For chained / cascade calls we just use toSource() of the
      // immediate target — that matches what users write in YAML.
      String? qualified;
      final receiver = node.target;
      if (receiver != null) {
        qualified = '${receiver.toSource()}.$method';
      }
      if (_matchesName(method, qualified)) matchCount++;
    }
    _enqueueIfFollowable(node.methodName.element);
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    if (_shouldStop) return;
    final fn = node.function;
    Element? el;
    if (fn is SimpleIdentifier) {
      el = fn.element;
    } else if (fn is PrefixedIdentifier) {
      el = fn.identifier.element;
    } else if (fn is PropertyAccess) {
      el = fn.propertyName.element;
    }
    _enqueueIfFollowable(el);
    super.visitFunctionExpressionInvocation(node);
  }

  // widget --------------------------------------------------------------
  // constructor ---------------------------------------------------------
  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_shouldStop) return;
    final namedType = node.constructorName.type;
    final className = namedType.name.lexeme;
    if (type == RuleTargetType.widget) {
      final dt = namedType.type;
      if (dt is InterfaceType && _isFlutterWidget(dt) && _matchesName(className)) {
        matchCount++;
      }
    } else if (type == RuleTargetType.constructor) {
      if (_matchesName(className)) matchCount++;
    }
    super.visitInstanceCreationExpression(node);
  }

  // named_argument ------------------------------------------------------
  @override
  void visitNamedExpression(NamedExpression node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.namedArgument) {
      if (_matchesName(node.name.label.name)) matchCount++;
    }
    // Tear-off arguments: `foo(onTap: trackTap)` — enqueue trackTap's
    // body so a constraint set on the *enclosing* call site (whose
    // scope wraps this NamedExpression) can still see into trackTap.
    final expr = node.expression;
    if (expr is SimpleIdentifier) {
      _enqueueIfFollowable(expr.element);
    } else if (expr is PrefixedIdentifier) {
      _enqueueIfFollowable(expr.identifier.element);
    } else if (expr is PropertyAccess) {
      _enqueueIfFollowable(expr.propertyName.element);
    }
    super.visitNamedExpression(node);
  }

  // function ------------------------------------------------------------
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.function) {
      if (_matchesName(node.name.lexeme)) matchCount++;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.function) {
      if (_matchesName(node.name.lexeme)) matchCount++;
    }
    super.visitMethodDeclaration(node);
  }

  // class ---------------------------------------------------------------
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.classDeclaration) {
      if (_matchesName(node.namePart.typeName.lexeme)) matchCount++;
    }
    super.visitClassDeclaration(node);
  }

  // import --------------------------------------------------------------
  @override
  void visitImportDirective(ImportDirective node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.importDirective) {
      if (_matchesName(node.uri.stringValue)) matchCount++;
    }
    super.visitImportDirective(node);
  }

  // annotation ----------------------------------------------------------
  @override
  void visitAnnotation(Annotation node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.annotation) {
      if (_matchesName(node.name.name)) matchCount++;
    }
    super.visitAnnotation(node);
  }

  // variable_declaration ------------------------------------------------
  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.variableDeclaration) {
      if (_matchesName(node.name.lexeme)) matchCount++;
    }
    super.visitVariableDeclaration(node);
  }

  // return_statement ----------------------------------------------------
  @override
  void visitReturnStatement(ReturnStatement node) {
    if (_shouldStop) return;
    if (type == RuleTargetType.returnStatement) {
      final returned = node.expression?.staticType?.element?.name ?? '';
      if (_matchesName(returned)) matchCount++;
    }
    super.visitReturnStatement(node);
  }

  /// Mirrors `WidgetTargetVisitor._isFlutterWidget` — kept duplicated to
  /// keep the two visitors independent (lifting a shared helper would
  /// only mask if the heuristic ever needs to diverge between them).
  static bool _isFlutterWidget(InterfaceType type) {
    if (type.element.name == 'Widget') return true;
    for (final supertype in type.allSupertypes) {
      if (supertype.element.name == 'Widget') return true;
    }
    return false;
  }
}
