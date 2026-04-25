/// The pipeline interface that target visitors call into when their target
/// match conditions are met.
///
/// This is the seam between two halves of the engine:
///
///   * **Target visitors** (`target_visitors.dart`) know nothing about the
///     YAML rule semantics beyond `target.type` + `target.names`. When they
///     see a node they like, they call [RuleEngine.onTargetMatched].
///   * **The umbrella rule** (`yaml_lint_rule.dart`) implements [RuleEngine]
///     and runs the rest of the pipeline: optional `when:` evaluation,
///     `must_contain` / `must_not_contain` / `count` constraints, scope
///     pre-filtering, and finally the diagnostic report.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';

import '../config/models.dart';

/// Implemented by `YamlLintRule`. Visitors only need this thin surface.
abstract class RuleEngine {
  /// Invoked by a target visitor when [reportAt] matched the rule's target
  /// criteria (type + names).
  ///
  /// [scope] is the AST node that subsequent constraint / condition checks
  /// should consider their universe. For most targets this is the matched
  /// node itself; for kinds like `function` it is the function body, for
  /// `named_argument` it is the argument's expression (typically a closure
  /// body), and so on. Visitors are responsible for computing it because the
  /// "where to look inside" depends on the target kind.
  ///
  /// [reportAt] is the AST node that diagnostics should be anchored to. If a
  /// diagnostic ends up being emitted, this is what gets the IDE squiggle.
  void onTargetMatched({
    required RuleConfig spec,
    required LintCode code,
    required AstNode reportAt,
    required AstNode scope,
  });
}
