# yaml_lint

> A declarative, YAML-driven static analysis engine for Dart & Flutter.
> Write rules in YAML — see them surface as native errors and warnings in
> the IDE and in `dart analyze` / `flutter analyze`.

`yaml_lint` is a Dart Analysis Server plugin (built on
[`analysis_server_plugin`][asp]) that lets a team encode architectural,
API, and convention rules in a single YAML file and have them enforced
exactly like first‑party `analyzer` lints. One Dart engine, many YAML
rules — **no Dart code per rule.**

---

## Why

| Tool | Role | Gap `yaml_lint` fills |
|------|------|------------------------|
| `flutter_lints`           | Curated static rule set                        | No config‑driven custom rules               |
| `analysis_server_plugin`  | Official Dart team plugin framework            | Forces you to write Dart per rule           |
| `dart_code_metrics`       | Predefined metrics                             | Not a generic config‑driven rule engine     |
| `import_rules`            | Dependency‑direction enforcement (YAML)        | Vertical, only the import graph             |

If your codebase has rules like *"every `onPressed` inside a `GestureDetector`
must call `Analytics.track`"*, *"no direct `print` in production code"*, or
*"factories named `fromJson` must return the enclosing type"*, `yaml_lint`
lets you express them once, in YAML, and forget about them.

## Quick start

```bash
# 1. Add yaml_lint as a dev dependency in your consumer project.
dart pub add --dev yaml_lint

# 2. From the project root, bootstrap a starter config.
dart run yaml_lint:init

# 3. Edit `lint_rules.yaml` to enable the rules you want.

# 4. Restart the Dart Analysis Server once
#    (Cmd/Ctrl ⇧ P → "Dart: Restart Analysis Server").
#    From now on, edits to `lint_rules.yaml` are hot-reloaded.

# 5. Run the analyzer like you always do.
dart analyze
```

That's it. Your rules will appear as native diagnostics in the IDE's
Problems panel and in `dart analyze` output, with whatever severity
you assigned (`error` / `warning` / `info`).

## Requirements

- Dart `^3.10` / Flutter `^3.38`.
- `analysis_server_plugin` exact‑pins `analyzer` per release;
  `yaml_lint` follows that lockstep. The current pin is
  `analysis_server_plugin: 0.3.7` ↔ `analyzer: ^10.0.0`. This
  pair is deliberately chosen to remain compatible with the
  `meta` version Flutter stable currently ships from its SDK
  (`1.17.0`). Newer analyzer lines (`10.0.2+`, `11.x`, `12.x`,
  `13.x`) bump the `meta` floor to `^1.18.0`, which Flutter
  stable can't satisfy until it ships a newer SDK.
- Cursor / VS Code with the Dart extension, IntelliJ / Android Studio,
  or any other editor that drives the standard Dart Analysis Server.

## Install

Add `yaml_lint` as a dev dependency:

```bash
dart pub add --dev yaml_lint
```

…or, equivalently, in `pubspec.yaml`:

```yaml
dev_dependencies:
  yaml_lint: ^0.1.0
```

Then bootstrap the project from its root:

```bash
dart run yaml_lint:init
```

`init` creates a starter `lint_rules.yaml` with three commented
examples and writes the matching `analysis_options.yaml` snippet. If
`analysis_options.yaml` already exists, it prints the snippet to
copy‑paste rather than editing the file in place.

If you'd rather wire it up by hand, add this to `analysis_options.yaml`:

```yaml
include: package:lints/recommended.yaml

plugins:
  yaml_lint:
    version: ^0.1.0
    # During local development on yaml_lint itself, swap `version:` for:
    # path: ../yaml_lint
```

> **Note.** The dev-dependency entry is what lets `dart run
> yaml_lint:init` and `dart run yaml_lint:validate` resolve the
> package. The analysis server itself loads the plugin from
> `analysis_options.yaml` independently — but adding it once as a
> dev-dep keeps both halves of the toolchain working consistently.

## Author your first rule

Create `lint_rules.yaml` next to your `pubspec.yaml`:

```yaml
version: 1

rules:
  - id: no_print
    description: |
      Flags every call to a method named `print`. Production code should
      use a structured logger instead.
    target:
      type: method_call
      names: [print]
    report:
      severity: error
      message: "Avoid 'print(...)' in production code; use a logger instead"
```

Save the file, then **restart the Dart Analysis Server**
(`Cmd/Ctrl ⇧ P → Dart: Restart Analysis Server` in VS Code / Cursor)
once. From then on the rule is hot‑reloaded on every save.

What you'll see in `dart analyze`:

```
$ dart analyze
Analyzing example...
  error - lib/main.dart:9:3 - Avoid 'print(...)' in production code; use a logger instead - no_print
1 issue found.
```

…and the same diagnostic, with the same severity and squiggle, in your
IDE.

## Suppressing a diagnostic

Use the standard `// ignore:` comment with the namespaced rule id:

```dart
// ignore: yaml_lint/no_print
print('intentional, e.g. inside a CLI tool entrypoint');
```

`// ignore_for_file: yaml_lint/no_print` works as well, just like for
first‑party lints.

## Validating your config

```bash
dart run yaml_lint:validate
```

Runs the same parser the analyzer plugin uses, so "validate green ⇒
analyzer green". Diagnostics are printed as
`path:line:col: severity: message` and the command exits non-zero on
any error — drop it into CI.

## DSL reference

Every rule is a `target` (where to look) plus a `report` (what to say).
Constraints (`must_contain`, `must_not_contain`, `count`), conditions
(`when`), and per-rule `scope:` extend that core. A top-level
`layers:` block lets architecture rules talk about layers by name.

```yaml
version: 1

# Optional: pull rules in from another YAML file. Cycles are detected.
includes:
  - shared/architecture.yaml

# Optional: declare your architectural layers. `import_from_layer:`
# in a `when:` then refers to a layer by name.
layers:
  domain:
    paths: ["lib/domain/**"]
  data:
    paths: ["lib/data/**"]

rules:
  - id: <snake_case_id>
    description: |
      Free‑form, multi‑line.
    target:
      type: method_call            # see "target.type values" below
      names: [foo, bar]            # optional; empty == match any

    when:                          # composable boolean conditions
      all:
        - inside_widget: GestureDetector
        - not:
            file_path: { contains: /generated/ }

    must_contain:
      method_call: [Analytics.track]
    must_not_contain:
      method_call: [print]
    count:
      target: method_call
      names: [print]
      max: 1

    scope:                         # per-rule file-level pre-filter
      include: ["lib/**"]
      exclude: ["lib/generated/**"]

    follow_calls: 1                # see "follow_calls" below

    report:
      severity: error | warning | info
      message: "Human-readable diagnostic text"
      code: optional_override_for_id   # surfaces in the IDE
      url: https://example.com/docs    # documentation link in the IDE
```

### `target.type` values

| `target.type`            | Matches |
|--------------------------|---------|
| `method_call`            | `MethodInvocation` whose name is in `names`. |
| `widget`                 | `InstanceCreationExpression` of a Flutter `Widget` whose class name is in `names`. |
| `constructor`            | `InstanceCreationExpression` whose class name is in `names`. |
| `named_argument`         | A `NamedExpression` (e.g. `onTap: …`) whose label is in `names`. |
| `function`               | `FunctionDeclaration` whose name is in `names`. |
| `class`                  | `ClassDeclaration` whose name is in `names`. |
| `import`                 | `ImportDirective` whose URI is in `names`. |
| `annotation`             | `Annotation` whose name is in `names`. |
| `variable_declaration`   | `VariableDeclaration` whose name is in `names`. |
| `return_statement`       | `ReturnStatement` whose returned expression has a static type in `names` (e.g. `dynamic`). |

`names` is optional — omit it to match every node of that target type.

### `when:` conditions

Conditions compose with the boolean operators `all:`, `any:`, and
`not:`. The available leaf predicates are:

| Predicate | Purpose |
|-----------|---------|
| `inside_widget: <Name>` | Some ancestor is a `Name` widget construction. |
| `inside_class_annotated_with: <A>` | The matched node lives in a class annotated with `@A`. |
| `file_matches: <glob>` | The current file matches the glob. |
| `file_path: { starts_with / ends_with / contains / regex: … }` | Path predicate (combined as AND when multiple sub-fields are set). |
| `callback_body_contains: [m, …]` | The enclosing function body calls one of `m`. |
| `callback_body_not_contains: [m, …]` | Inverse of the previous. |
| `class_name_matches: <regex>` | Enclosing class name matches the regex. |
| `method_name_starts_with: <str>` | Enclosing method/function name starts with `str`. |
| `import_from_layer: <layer>` | The file imports something from the named `layers:` entry. |

### `follow_calls:` recursive constraints

By default, `must_contain` / `must_not_contain` / `count` only inspect
the literal AST scope handed in by the target visitor. For
`target: named_argument` that scope is just the closure body (or the
tear-off identifier) — so a rule like

```yaml
target: { type: named_argument, names: [onTap] }
must_contain: { method_call: [Analytics.track] }
```

would fire on `onTap: () => trackTap()` even when `trackTap()` itself
calls `Analytics.track`, because the literal closure body has no
direct call. Setting `follow_calls:` widens that universe one or more
levels deep:

```yaml
follow_calls: 1                  # sugar — depth 1, same package only
# or:
follow_calls:
  max_depth: 2                   # 0 disables; ≥1 enables
  same_package_only: true        # (default — see caveats below)
```

When enabled, the engine descends into every callee invoked from the
scope (and from each callee in turn, up to `max_depth` levels), with
a cycle guard so mutual recursion can't loop. Tear-offs are handled
too: `onLongPress: trackLongPress` is treated as if it were
`onLongPress: () { trackLongPress(); }`.

**Caveats**

- The plugin can only reach declarations inside the *same library* as
  the file under analysis (main file + any `part of` parts). Calls
  into other libraries or packages — including `dart:core`,
  `package:flutter`, and other in-project libraries — are silently
  skipped. This is a limitation of the public
  `analysis_server_plugin` API: cross-library AST lookup is not
  exposed there. `same_package_only: false` is accepted but produces
  a YAML warning explaining the same constraint applies at runtime.
- `follow_calls:` widens *both* halves of a constraint. With
  `must_not_contain: { method_call: [print] }` and `follow_calls: 1`,
  a `print()` reachable through any one-deep callee will trip the
  rule. If you only want the literal-body semantics, leave
  `follow_calls` unset.

### Discovery & hot‑reload

- The plugin resolves your project root **per analysis context** from the
  Dart Analysis Server's own per‑library package resolution
  (`RuleContext.package.root`), with a `pubspec.yaml` walk‑up fallback.
  This means it Just Works inside the IDE — there is no `Directory.current`
  heuristic that breaks for IDE‑launched plugin isolates.
- `lint_rules.yaml` is cached by `(projectRoot, mtime)`. Editing the file
  invalidates the cache on the next analyzer tick — no plugin restart
  required.

## CLI tools

| Command                                | What it does |
|----------------------------------------|--------------|
| `dart run yaml_lint:init`              | Bootstrap a project (creates `lint_rules.yaml`, prints `analysis_options.yaml` snippet). CREATE-ONLY: never patches existing files unless `--force`. |
| `dart run yaml_lint:validate`          | Structural + semantic linter for `lint_rules.yaml`. Exits non-zero on errors so it's CI-friendly. |

Both commands accept `--root <dir>` to target another project, and
`--help` for the full option list.

## Repository layout

```
yaml_lint/
├── bin/
│   ├── init.dart                  ← `dart run yaml_lint:init`
│   └── validate.dart              ← `dart run yaml_lint:validate`
├── lib/
│   ├── main.dart                  ← Plugin entry point
│   └── src/
│       ├── config/                ← models / parser / loader (+ `includes:`)
│       ├── engine/                ← target router, visitors, conditions, constraints
│       └── rules/                 ← umbrella MultiAnalysisRule
├── example/                       ← End-to-end smoke-test consumer
└── test/                          ← Unit tests for parser / loader / engine / rule wiring
```

## Development

```bash
# Run the unit test suite
dart test

# Smoke-test the plugin end-to-end against the sample consumer
cd example
dart analyze
```

If the IDE seems to be running stale code, force a clean rebuild with:

```bash
rm -rf ~/.dartServer/.plugin_manager/*
```

…and then `Dart: Restart Analysis Server`.

## Contributing

Issues, bug reports, and DSL design feedback are all welcome. Please
attach the YAML rule and a minimal reproducer when reporting
analyzer-side problems; a copy of `lint_rules.yaml` plus the offending
Dart source is usually enough to reproduce.

## License

Apache‑2.0. See [`LICENSE`](LICENSE).

[asp]: https://pub.dev/packages/analysis_server_plugin
