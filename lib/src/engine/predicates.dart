/// Leaf-predicate implementations for the `when:` evaluator.
///
/// Kept separate from `conditions.dart` so the dispatch (the sealed
/// switch) is one short file and the AST/logic-heavy code lives here.
/// All methods are static — predicates are pure functions of their
/// inputs, with no engine state to carry around.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

class Predicates {
  Predicates._();

  /// `inside_widget: <Name>` — walk up [start] looking for an
  /// `InstanceCreationExpression` whose constructed type extends Flutter's
  /// `Widget` and is named [widgetName].
  ///
  /// Mirrors `WidgetTargetVisitor`'s name-based supertype check, so a
  /// project doesn't have to depend on `package:flutter` to use this
  /// predicate.
  static bool insideWidget(AstNode start, String widgetName) {
    AstNode? cursor = start.parent;
    while (cursor != null) {
      if (cursor is InstanceCreationExpression) {
        final namedType = cursor.constructorName.type;
        if (namedType.name.lexeme == widgetName) {
          final dt = namedType.type;
          // Without resolved types we can still match by name as a
          // best-effort. With resolved types we *also* verify the
          // ancestor is a Widget — same heuristic as the visitor.
          if (dt is! InterfaceType || _isFlutterWidget(dt)) return true;
        }
      }
      cursor = cursor.parent;
    }
    return false;
  }

  /// `inside_class_annotated_with: <A>` — walk up to the nearest enclosing
  /// `ClassDeclaration` and return whether any of its `@`-annotations
  /// has [annotationName].
  ///
  /// Matching is by syntactic name, not resolved element. That lets the
  /// rule fire even on annotation classes that haven't been imported by
  /// the analyzer yet (or in unresolved AST contexts).
  static bool insideClassAnnotatedWith(AstNode start, String annotationName) {
    final cls = start.thisOrAncestorOfType<ClassDeclaration>();
    if (cls == null) return false;
    for (final annotation in cls.metadata) {
      if (annotation.name.name == annotationName) return true;
    }
    return false;
  }

  /// `file_matches: <glob>` — match the consumer's file path against a
  /// shell-style glob. We use `package:glob`'s `Glob.matches` directly;
  /// it normalises path separators on Windows for us.
  static bool fileMatches(String filePath, String pattern) {
    try {
      return Glob(pattern).matches(filePath);
    } on FormatException {
      // Author error in the YAML; surfaced at parse time as a diagnostic
      // already (we eagerly compile globs in the parser). Treat any late
      // failure as "predicate doesn't apply" — never crash the analyzer.
      return false;
    }
  }

  /// `file_path: { ... }` — checks whichever single sub-field is set.
  /// The parser already enforces "at least one set"; if multiple are
  /// passed (which the parser tolerates) we treat them as AND.
  static bool filePath(
    String filePath, {
    String? startsWith,
    String? endsWith,
    String? contains,
    String? regex,
  }) {
    if (startsWith != null && !filePath.startsWith(startsWith)) return false;
    if (endsWith != null && !filePath.endsWith(endsWith)) return false;
    if (contains != null && !filePath.contains(contains)) return false;
    if (regex != null) {
      try {
        if (!RegExp(regex).hasMatch(filePath)) return false;
      } on FormatException {
        return false;
      }
    }
    return true;
  }

  /// `callback_body_contains: [m, ...]` — finds the closest enclosing
  /// `FunctionBody`, then walks it for a `MethodInvocation` whose
  /// (qualified or short) name appears in [methodNames]. Returns `true`
  /// if any match is found.
  ///
  /// The "callback body" lookup is the closest `FunctionBody`, which
  /// covers both top-level functions and arrow/closure callbacks
  /// (`onTap: () { ... }`, `onTap: () => foo()`, etc.).
  static bool callbackBodyContains(AstNode start, List<String> methodNames) {
    final body = _enclosingBody(start);
    if (body == null) return false;
    final visitor = _MethodCallNameVisitor(methodNames);
    body.accept(visitor);
    return visitor.found;
  }

  /// `class_name_matches: <regex>` — check the matched node's enclosing
  /// `ClassDeclaration` name against [regex].
  static bool classNameMatches(AstNode start, String regex) {
    final cls = start.thisOrAncestorOfType<ClassDeclaration>();
    if (cls == null) return false;
    try {
      return RegExp(regex).hasMatch(cls.namePart.typeName.lexeme);
    } on FormatException {
      return false;
    }
  }

  /// `method_name_starts_with: <str>` — closest enclosing function or
  /// method declaration, name compared with `startsWith`.
  static bool methodNameStartsWith(AstNode start, String prefix) {
    AstNode? cursor = start;
    while (cursor != null) {
      if (cursor is MethodDeclaration) {
        return cursor.name.lexeme.startsWith(prefix);
      }
      if (cursor is FunctionDeclaration) {
        return cursor.name.lexeme.startsWith(prefix);
      }
      cursor = cursor.parent;
    }
    return false;
  }

  /// `import_from_layer: <layer>` — does the file under analysis import
  /// any path declared under `layers.<layer>`?
  ///
  /// Layer paths in `lint_rules.yaml` are file globs (e.g.
  /// `lib/data/**`), so we match each `import` directive's *resolved*
  /// library file path against those globs. We fall back to the raw
  /// URI string for unresolved imports — it lets `package:foo/...`
  /// imports match a `package:foo/**` glob, which is sometimes useful
  /// even though it's not the primary supported shape.
  static bool importFromLayer(
    AstNode start,
    String filePath,
    String layer,
    Map<String, List<String>>? layers, {
    String? projectRoot,
  }) {
    final patterns = layers?[layer];
    if (patterns == null || patterns.isEmpty) return false;
    final unit = start.thisOrAncestorOfType<CompilationUnit>();
    if (unit == null) return false;
    final globs = patterns.map(Glob.new).toList(growable: false);
    for (final directive in unit.directives) {
      if (directive is! ImportDirective) continue;
      final candidates = _layerCandidatesForImport(directive, projectRoot);
      for (final candidate in candidates) {
        for (final g in globs) {
          if (g.matches(candidate)) return true;
        }
      }
    }
    return false;
  }

  /// Builds the list of strings the `layers:` globs are matched
  /// against, in priority order:
  ///
  /// 1. Project-relative resolved file path (POSIX-slashed) — primary
  ///    match for `lib/data/**`-style globs in monorepo or single-pkg
  ///    setups.
  /// 2. Absolute resolved file path — for projects whose config uses
  ///    absolute globs (rare but supported).
  /// 3. Raw URI string from the directive — supports
  ///    `package:foo/...` globs and unresolved imports.
  static List<String> _layerCandidatesForImport(
    ImportDirective directive,
    String? projectRoot,
  ) {
    final out = <String>[];
    final resolvedPath = directive
        .libraryImport
        ?.importedLibrary
        ?.firstFragment
        .source
        .fullName;
    if (resolvedPath != null) {
      if (projectRoot != null && p.isWithin(projectRoot, resolvedPath)) {
        out.add(p.posix.joinAll(p.split(p.relative(
          resolvedPath,
          from: projectRoot,
        ))));
      }
      out.add(resolvedPath);
    }
    final uri = directive.uri.stringValue;
    if (uri != null) out.add(uri);
    return out;
  }

  static FunctionBody? _enclosingBody(AstNode start) {
    AstNode? cursor = start;
    while (cursor != null) {
      if (cursor is FunctionBody) return cursor;
      cursor = cursor.parent;
    }
    return null;
  }

  static bool _isFlutterWidget(InterfaceType type) {
    if (type.element.name == 'Widget') return true;
    for (final supertype in type.allSupertypes) {
      if (supertype.element.name == 'Widget') return true;
    }
    return false;
  }
}

/// One-shot recursive walker that returns true after the first
/// `MethodInvocation` whose name (short or `Receiver.method`) matches.
class _MethodCallNameVisitor extends RecursiveAstVisitor<void> {
  _MethodCallNameVisitor(this.names);

  final List<String> names;
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (found) return;
    final method = node.methodName.name;
    if (names.contains(method)) {
      found = true;
      return;
    }
    final receiver = node.target;
    if (receiver != null) {
      final qualified = '${receiver.toSource()}.$method';
      if (names.contains(qualified)) {
        found = true;
        return;
      }
    }
    super.visitMethodInvocation(node);
  }
}
