// Fixture for `no_print_outside_lib`.
//
// The rule's `scope:` is `include: [bin/**, tool/**]`, so this
// file qualifies and the `print()` below fires. The same call inside
// `lib/main.dart` is *not* flagged by this rule (it would only be
// flagged by `limit_print_spammer` / `no_print_in_setup`, which use a
// different mechanism).

void main() {
  print('build script started');
}
