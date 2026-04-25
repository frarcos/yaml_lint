/// `yaml_lint` is consumed as an analysis server plugin, not as a Dart
/// library. There is intentionally no public Dart API.
///
/// To use it, enable the plugin in your `analysis_options.yaml`:
///
/// ```yaml
/// plugins:
///   yaml_lint: ^0.1.0
///     diagnostics:
///       no_print: true
/// ```
///
/// See the README for the full YAML DSL.
library;
