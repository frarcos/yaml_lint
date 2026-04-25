/// `when:` condition evaluator.
///
/// Once a target visitor finds a candidate node, the umbrella rule asks
/// the evaluator: "given this AST node, this file path, and the layers
/// map, does the rule's `when:` predicate hold?" Only if the answer is
/// yes does the constraint stage run.
///
/// The evaluator is a single exhaustive `switch` over the sealed
/// [Condition] hierarchy in `models.dart`. New leaves *must* be added
/// to that switch; the compiler enforces it.
library;

import 'package:analyzer/dart/ast/ast.dart';

import '../config/models.dart';
import 'predicates.dart';

/// Per-evaluation read-only state.
///
/// Constructed once per `onTargetMatched` invocation; passed through the
/// recursive evaluator so leaf predicates have everything they need
/// without any global state.
class ConditionContext {
  const ConditionContext({
    required this.matchedNode,
    required this.filePath,
    this.projectRoot,
    this.layers,
  });

  /// The AST node the target visitor matched. Leaf predicates that need
  /// to walk up the tree (e.g. `inside_widget`) start from here.
  final AstNode matchedNode;

  /// Absolute path of the file under analysis. Used by `file_*`
  /// predicates and `import_from_layer`.
  final String filePath;

  /// Absolute path of the consumer project root. Used to convert
  /// resolved import paths to project-relative form so `layers:` globs
  /// like `lib/data/**` can match them. `null` when no enclosing
  /// package was found (rare; the umbrella rule does its best).
  final String? projectRoot;

  /// `layers:` block from the project's config. `import_from_layer`
  /// returns `false` when this is `null` or empty.
  final Map<String, List<String>>? layers;
}

class ConditionEvaluator {
  const ConditionEvaluator();

  /// Returns `true` iff [c] is satisfied in [ctx].
  bool evaluate(Condition c, ConditionContext ctx) => switch (c) {
    AllCondition(:final children) =>
      children.every((child) => evaluate(child, ctx)),
    AnyCondition(:final children) =>
      children.any((child) => evaluate(child, ctx)),
    NotCondition(:final child) => !evaluate(child, ctx),
    InsideWidgetCondition(:final widgetName) =>
      Predicates.insideWidget(ctx.matchedNode, widgetName),
    InsideClassAnnotatedWithCondition(:final annotationName) =>
      Predicates.insideClassAnnotatedWith(ctx.matchedNode, annotationName),
    FileMatchesCondition(:final glob) =>
      Predicates.fileMatches(ctx.filePath, glob),
    FilePathCondition(
      :final startsWith,
      :final endsWith,
      :final contains,
      :final regex,
    ) =>
      Predicates.filePath(
        ctx.filePath,
        startsWith: startsWith,
        endsWith: endsWith,
        contains: contains,
        regex: regex,
      ),
    CallbackBodyContainsCondition(:final methodNames) =>
      Predicates.callbackBodyContains(ctx.matchedNode, methodNames),
    CallbackBodyNotContainsCondition(:final methodNames) =>
      !Predicates.callbackBodyContains(ctx.matchedNode, methodNames),
    ClassNameMatchesCondition(:final regex) =>
      Predicates.classNameMatches(ctx.matchedNode, regex),
    MethodNameStartsWithCondition(:final prefix) =>
      Predicates.methodNameStartsWith(ctx.matchedNode, prefix),
    ImportFromLayerCondition(:final layer) =>
      Predicates.importFromLayer(
        ctx.matchedNode,
        ctx.filePath,
        layer,
        ctx.layers,
        projectRoot: ctx.projectRoot,
      ),
  };
}
