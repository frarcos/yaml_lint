// Fixture for `domain_is_pure` (layers + import_from_layer).
//
// `lint_rules.yaml` declares `lib/data/**` as the `data` layer; this
// import resolves to that layer, so the rule fires on the import
// directive below. The matching `data` file is intentionally minimal.

// ignore_for_file: unused_import

import 'package:yaml_lint_example/data/repo.dart';

class Order {}
