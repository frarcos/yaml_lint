# Changelog

## 0.1.0

Initial public release.

- Analysis Server plugin built on `analysis_server_plugin` (pinned to
  the `0.3.7` ↔ `analyzer 10.0.x` lockstep pair so the package remains
  installable alongside Flutter stable, which currently ships
  `meta: 1.17.0` from its SDK).
- YAML rule DSL with all 10 `target.type` kinds (`method_call`, `widget`,
  `constructor`, `named_argument`, `function`, `class`, `import`,
  `annotation`, `variable_declaration`, `return_statement`).
- `when:` predicate tree (`all`/`any`/`not` plus 9 leaf predicates).
- Constraints: `must_contain`, `must_not_contain`, `count` with optional
  `follow_calls:` recursive descent into project-local callees.
- Per-rule `scope:` glob-based file pre-filter.
- Top-level `layers:` block + `import_from_layer:` predicate for
  architecture rules.
- `includes:` (cycle-detected YAML composition).
- Per-rule severity (`error` / `warning` / `info`) and `report.url`
  surfaced to the IDE's Problems panel.
- `// ignore: yaml_lint/<id>` and `ignore_for_file:` support, identical
  to first-party analyzer lints.
- Lazy per-analysis-context project resolution with mtime-keyed cache —
  hot-reloads `lint_rules.yaml` without restarting the analysis server.
- `dart run yaml_lint:init` and `dart run yaml_lint:validate` CLIs.
