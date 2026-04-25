/// Entry point required by `analysis_server_plugin`.
///
/// The Dart Analysis Server imports this file and references the top-level
/// [plugin] variable to load the plugin into its isolate.
///
/// ## Lifecycle
///
/// `register()` is intentionally trivial: it registers a single umbrella
/// rule named `yaml_lint`. **No I/O, no project discovery.**
///
/// All `lint_rules.yaml` discovery and compilation happens lazily, per
/// analysis context, inside `YamlLintRule.registerNodeProcessors` — that's
/// where the framework finally hands us a `RuleContext.package` whose
/// `root.path` is the consumer's project root. See `yaml_lint_rule.dart`
/// for the full rationale and the cache shape.
library;

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/rules/yaml_lint_rule.dart';

final plugin = YamlLintPlugin();

class YamlLintPlugin extends Plugin {
  @override
  String get name => kYamlLintRuleName;

  @override
  void register(PluginRegistry registry) {
    final rule = YamlLintRule();
    // Best-effort warm-up so `dart analyze` / `flutter analyze` get full
    // severity & ignore-comment fidelity on the very first (and, for one-
    // shot CLI invocations, only) analysis cycle. No-op in IDE-launched
    // isolates. See `YamlLintRule.warmUpFromCwd` for the full rationale.
    rule.warmUpFromCwd();
    registry.registerLintRule(rule);
  }
}
