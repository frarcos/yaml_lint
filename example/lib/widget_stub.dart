// Minimal stand-ins for Flutter primitives so the example package can
// exercise yaml_lint without a Flutter dependency.
//
// `WidgetTargetVisitor` and `_MatchVisitor` both detect "is this an
// `InstanceCreationExpression` whose constructed type extends `Widget`?"
// purely by walking `InterfaceType.allSupertypes` looking for a class
// named `Widget`. Anything that ultimately extends [Widget] below will
// therefore match `target: widget` rules.

class Widget {
  const Widget();
}

class Container extends Widget {
  const Container({this.child});

  final Widget? child;
}

/// Used to demonstrate the `named_argument` target combined with
/// `must_contain` — see `example/lint_rules.yaml`'s
/// `include_analytics_tracking` rule.
class Button extends Widget {
  const Button({
    this.onTap,
    this.onPressed,
    this.onLongPress,
    this.onSecondary,
  });

  final void Function()? onTap;
  final void Function()? onPressed;
  final void Function()? onLongPress;
  final void Function()? onSecondary;
}
