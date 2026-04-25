// Demo file used to verify yaml_lint's analyzer plugin end-to-end.
//
// Each section below deliberately triggers exactly one yaml_lint rule
// from `lint_rules.yaml`, and silences any neighbouring built-in lint
// noise so `dart analyze` shows yaml_lint's diagnostics with no
// distraction. Section numbering matches the YAML.

// ignore_for_file: unused_local_variable, unused_element, deprecated_member_use_from_same_package, avoid_print, no_print, provide_deprecation_message, prefer_typing_uninitialized_variables

// 6. import — `no_dart_io` flags this URI.
import 'dart:io';

import 'widget_stub.dart';

// 7. annotation — `no_deprecated_annotation` flags `@deprecated`.
@deprecated
void main() {
  // 1. method_call — `no_legacy_callback` flags this call.
  legacyCallback();

  // 2. widget — `no_container_widget` flags `Container(...)`.
  final box = Container();

  // 3. constructor — `no_legacy_service` flags `LegacyService(...)`.
  final svc = LegacyService();

  // 4. function — `no_legacy_function` flags the declaration of
  //    `legacyFunc` below. (Calling it here is fine; the rule fires
  //    on the declaration site.)
  legacyFunc();

  // 8. variable_declaration — `no_legacy_var` flags this declaration.
  final legacyVar = 42;

  // 9. return_statement — `no_dynamic_returns` flags the `return`
  //    inside `giveAnything()` whose expression is dynamically typed.
  final r = giveAnything();

  // 10. named_argument + must_contain + follow_calls — every callback
  //     ultimately reaches Analytics.track, even though the literal
  //     closure body for onPressed and onLongPress doesn't call it
  //     directly. follow_calls: 1 lets the engine descend one level
  //     into doSomething() / trackLongPress() to find the call.
  Button(
    onTap: () {
      Analytics.track('tap');
    },
    onPressed: () {
      doSomething();
    },
    onLongPress: trackLongPress,
  );

  // 10b. The "negative" case for the same rule — `onSecondary` neither
  //      tracks directly nor delegates to anything that does, so even
  //      with follow_calls: 1 the rule still fires here.
  Button(
    onSecondary: () {
      doNothing();
    },
  );

  // 11. method_call + must_not_contain — setUp's closure prints.
  setUp(() {
    print('print() in setUp() is forbidden');
  });

  // 12. function + count — printSpammer calls print() twice (> max:1).
  printSpammer();

  // Keep dart:io "used" so the import survives — otherwise the
  // analyzer would also flag the unused import on top of yaml_lint.
  stdout.writeln('hi');
}

void legacyCallback() {}

// 4. The function declaration that `no_legacy_function` flags.
void legacyFunc() {}

// 5. The class declaration that `no_legacy_class` flags.
class LegacyClass {}

class LegacyService {}

class Analytics {
  static void track(String event) {}
}

void doSomething() {
  Analytics.track('doSomething');
}

/// Tear-off target referenced by `onLongPress: trackLongPress`. The
/// engine recognises bare-identifier named arguments as a tear-off and
/// uses this body as the level-0 walk when follow_calls is enabled.
void trackLongPress() {
  Analytics.track('long_press');
}

/// Helper used by section 10b's negative case: it transitively never
/// reaches Analytics.track, so the rule fires even with follow_calls.
void doNothing() {
  // intentionally empty — nothing tracked here.
}

/// Stand-in for `package:test`'s `setUp`; mirrors the signature so the
/// rule has something to bind to in this Flutter-free example.
void setUp(void Function() body) => body();

// 12. Two `print()` calls in this body trigger `limit_print_spammer`.
void printSpammer() {
  print('1');
  print('2');
}

// 9. The function whose return statement has a dynamic-typed expression.
//
// The cast through a `dynamic`-typed local is what gives the *expression*
// (not the function) a static type of `dynamic`, which is what the
// `ReturnStatementTargetVisitor` matches against.
Object giveAnything() {
  final dynamic anything = 'hello';
  return anything;
}
