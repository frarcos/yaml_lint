/// Parser coverage for `when:` (the sealed `Condition` tree).
library;

import 'package:test/test.dart';
import 'package:yaml_lint/src/config/models.dart';
import 'package:yaml_lint/src/config/parser.dart';

void main() {
  group('parseRuleSet (when:)', () {
    test('parses a flat leaf predicate', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [print] }
    when:
      file_matches: 'lib/**/*.dart'
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty);
      final when = result.ruleSet.rules.single.when;
      expect(when, isA<FileMatchesCondition>());
      expect((when! as FileMatchesCondition).glob, 'lib/**/*.dart');
    });

    test('parses all/any/not boolean composition', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    when:
      all:
        - any:
            - inside_widget: Container
            - inside_widget: Box
        - not:
            file_path: { contains: '/generated/' }
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty);
      final when = result.ruleSet.rules.single.when;
      expect(when, isA<AllCondition>());

      final all = when! as AllCondition;
      expect(all.children, hasLength(2));
      expect(all.children.first, isA<AnyCondition>());
      expect(all.children.last, isA<NotCondition>());

      final any = all.children.first as AnyCondition;
      expect(
        any.children.map((c) => (c as InsideWidgetCondition).widgetName),
        ['Container', 'Box'],
      );

      final notCond = all.children.last as NotCondition;
      expect(notCond.child, isA<FilePathCondition>());
      expect((notCond.child as FilePathCondition).contains, '/generated/');
    });

    test('parses every leaf predicate', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    when:
      all:
        - inside_widget: MyWidget
        - inside_class_annotated_with: Riverpod
        - file_matches: 'lib/**'
        - file_path: { starts_with: 'lib/' }
        - file_path: { ends_with: '.g.dart' }
        - file_path: { contains: 'features' }
        - file_path: { regex: '^lib/.*\\.dart\$' }
        - callback_body_contains: [Analytics.track, log]
        - callback_body_not_contains: [print]
        - class_name_matches: '^[A-Z].*State\$'
        - method_name_starts_with: build
        - import_from_layer: domain
    report: { severity: warning, message: m }
''');
      expect(result.diagnostics, isEmpty,
          reason: result.diagnostics.map((d) => d.message).join('\n'));
      final all = result.ruleSet.rules.single.when! as AllCondition;
      expect(all.children, hasLength(12));

      expect(all.children[0], isA<InsideWidgetCondition>());
      expect(all.children[1], isA<InsideClassAnnotatedWithCondition>());
      expect(all.children[2], isA<FileMatchesCondition>());
      expect(all.children[3], isA<FilePathCondition>());
      expect((all.children[3] as FilePathCondition).startsWith, 'lib/');
      expect((all.children[4] as FilePathCondition).endsWith, '.g.dart');
      expect((all.children[5] as FilePathCondition).contains, 'features');
      expect((all.children[6] as FilePathCondition).regex, isNotNull);
      expect(all.children[7], isA<CallbackBodyContainsCondition>());
      expect(
        (all.children[7] as CallbackBodyContainsCondition).methodNames,
        ['Analytics.track', 'log'],
      );
      expect(all.children[8], isA<CallbackBodyNotContainsCondition>());
      expect(all.children[9], isA<ClassNameMatchesCondition>());
      expect(all.children[10], isA<MethodNameStartsWithCondition>());
      expect((all.children[10] as MethodNameStartsWithCondition).prefix,
          'build');
      expect(all.children[11], isA<ImportFromLayerCondition>());
      expect((all.children[11] as ImportFromLayerCondition).layer, 'domain');
    });

    test('reports an unknown leaf predicate but keeps the rule', () {
      final result = parse('''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    when:
      gibberish: yes
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('gibberish'),
      );
      // The rule is still loaded; the bad `when:` becomes a no-op.
      expect(result.ruleSet.rules, hasLength(1));
    });

    test('rejects an invalid regex eagerly', () {
      final result = parse(r'''
rules:
  - id: r1
    target: { type: method_call, names: [foo] }
    when:
      file_path: { regex: '[unterminated' }
    report: { severity: warning, message: m }
''');
      expect(
        result.diagnostics.map((d) => d.message).join(' | '),
        contains('regex'),
      );
    });
  });
}

ConfigLoadResult parse(String yaml) =>
    parseRuleSet(yamlSource: yaml, sourceFile: '/test.yaml');
