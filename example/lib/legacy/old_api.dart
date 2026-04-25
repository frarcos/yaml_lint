// Demo file for the `when:` predicates.
//
// `lint_rules.yaml`'s `secret_api_legacy_only` rule fires on
// `secretApi()` calls *only* when the file path contains `/legacy/`
// AND the enclosing function name doesn't start with `trusted`.
// This file lives under `lib/legacy/` so the file-path predicate is
// satisfied; the two functions below differ only by their name, so
// each demonstrates one side of the boolean.

// ignore_for_file: unused_local_variable, unused_element

void someCaller() {
  // Both predicates pass → the rule fires here.
  secretApi();
}

void trustedCaller() {
  // `method_name_starts_with: trusted` short-circuits the `not:`,
  // so the rule does *not* fire here.
  secretApi();
}

void secretApi() {}
