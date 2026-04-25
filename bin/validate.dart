/// `dart run yaml_lint:validate` — structural & semantic linter for the
/// project's `lint_rules.yaml`.
///
/// Designed for CI: parses the same way the analyzer plugin does (so
/// "validate green ⇒ analyzer green"), prints human-readable
/// diagnostics with `path:line:col: severity: message`, and exits
/// non-zero on errors.
///
/// Usage:
///
/// ```sh
/// dart run yaml_lint:validate                  # defaults to CWD
/// dart run yaml_lint:validate --root path/...  # custom project root
/// dart run yaml_lint:validate --config path    # explicit config file
/// ```
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:yaml_lint/src/config/loader.dart';
import 'package:yaml_lint/src/config/models.dart';

void main(List<String> args) {
  exitCode = _run(args, stdout: stdout, stderr: stderr);
}

int _run(
  List<String> args, {
  required IOSink stdout,
  required IOSink stderr,
}) {
  String? rootArg;
  String? configArg;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--help':
      case '-h':
        _printHelp(stdout);
        return 0;
      case '--root':
        if (i + 1 >= args.length) {
          stderr.writeln('--root requires a value.');
          return 64;
        }
        rootArg = args[++i];
      case '--config':
        if (i + 1 >= args.length) {
          stderr.writeln('--config requires a value.');
          return 64;
        }
        configArg = args[++i];
      default:
        if (a.startsWith('--root=')) {
          rootArg = a.substring('--root='.length);
        } else if (a.startsWith('--config=')) {
          configArg = a.substring('--config='.length);
        } else {
          stderr.writeln("Unknown argument '$a'. Run with --help.");
          return 64;
        }
    }
  }

  final root = p.absolute(rootArg ?? Directory.current.path);
  if (!Directory(root).existsSync()) {
    stderr.writeln("Root directory '$root' does not exist.");
    return 66;
  }

  final result = loadProjectConfig(
    projectRoot: root,
    overridePath: configArg,
  );

  // No diagnostics, no rules → no config file present at all.
  if (result.diagnostics.isEmpty && result.ruleSet.rules.isEmpty) {
    stderr.writeln(
      "No lint_rules.yaml found under '$root'. "
      'Run `dart run yaml_lint:init` to create one.',
    );
    return 66;
  }

  var errors = 0;
  var warnings = 0;
  for (final d in result.diagnostics) {
    final tag = switch (d.severity) {
      ConfigDiagnosticSeverity.error => 'error',
      ConfigDiagnosticSeverity.warning => 'warning',
    };
    final span = d.span;
    final loc = span == null
        ? '<config>'
        : _formatLocation(span.sourceUrl, span.start.line, span.start.column);
    stdout.writeln('$loc: $tag: ${d.message}');
    if (d.severity == ConfigDiagnosticSeverity.error) errors++;
    if (d.severity == ConfigDiagnosticSeverity.warning) warnings++;
  }

  final summary = StringBuffer()
    ..write('${result.ruleSet.rules.length} rule')
    ..write(result.ruleSet.rules.length == 1 ? '' : 's');
  if (result.ruleSet.layers.isNotEmpty) {
    summary
      ..write(', ')
      ..write(result.ruleSet.layers.length)
      ..write(' layer')
      ..write(result.ruleSet.layers.length == 1 ? '' : 's');
  }
  summary
    ..write(', ')
    ..write(errors)
    ..write(' error')
    ..write(errors == 1 ? '' : 's')
    ..write(', ')
    ..write(warnings)
    ..write(' warning')
    ..write(warnings == 1 ? '' : 's');
  stdout.writeln('');
  stdout.writeln(summary.toString());

  return errors == 0 ? 0 : 1;
}

String _formatLocation(Uri? sourceUrl, int line, int column) {
  String pathStr;
  if (sourceUrl == null) {
    pathStr = '<config>';
  } else if (sourceUrl.scheme == 'file') {
    try {
      pathStr = p.relative(sourceUrl.toFilePath());
    } catch (_) {
      pathStr = sourceUrl.toString();
    }
  } else {
    pathStr = sourceUrl.toString();
  }
  return '$pathStr:${line + 1}:${column + 1}';
}

void _printHelp(IOSink stdout) {
  stdout.writeln('''
Usage: dart run yaml_lint:validate [options]

Validates the project's lint_rules.yaml. Prints diagnostics with file
locations and exits non-zero on any error so it's drop-in for CI.

Options:
  --root <dir>     Project root to validate (defaults to current directory).
  --config <path>  Explicit config file to load (relative to --root or absolute).
  --help, -h       Print this help message.
''');
}
