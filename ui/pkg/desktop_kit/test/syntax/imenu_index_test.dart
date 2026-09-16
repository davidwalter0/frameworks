import 'package:desktop_kit/desktop_kit_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('imenuIndex', () {
    test('none language always returns empty', () {
      expect(imenuIndex('anything at all\nmore text', SyntaxLanguage.none),
          isEmpty);
    });

    test('org: headings indented by level, title text only', () {
      const String text = '* Top\n'
          'body line\n'
          '** Child\n'
          '*** Grandchild\n'
          '** Second Child\n'
          '* Second Top';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.org);
      expect(entries, <ImenuEntry>[
        (title: 'Top', line: 0),
        (title: '  Child', line: 2),
        (title: '    Grandchild', line: 3),
        (title: '  Second Child', line: 4),
        (title: 'Second Top', line: 5),
      ]);
    });

    test('org: non-heading lines are not indexed', () {
      const String text = 'not a heading\n* Real Heading\nplain text';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.org);
      expect(entries, <ImenuEntry>[(title: 'Real Heading', line: 1)]);
    });

    test('elisp: top-level defuns, title is the function name', () {
      const String text = ';; comment\n'
          '(defun foo-bar (x)\n'
          '  (+ x 1))\n'
          '\n'
          '(defun baz! ()\n'
          '  nil)\n';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.elisp);
      expect(entries, <ImenuEntry>[
        (title: 'foo-bar', line: 1),
        (title: 'baz!', line: 4),
      ]);
    });

    test('elisp: non-defun forms are not indexed', () {
      const String text =
          '(defvar my-var 1)\n(setq x 2)\n(defun real-fn () nil)';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.elisp);
      expect(entries, <ImenuEntry>[(title: 'real-fn', line: 2)]);
    });

    test('go: funcs and methods, title excludes the receiver', () {
      const String text = 'package main\n'
          '\n'
          'func Foo(x int) int {\n'
          '\treturn x\n'
          '}\n'
          '\n'
          'func (r *Receiver) Bar() error {\n'
          '\treturn nil\n'
          '}\n';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.go);
      expect(entries, <ImenuEntry>[
        (title: 'Foo', line: 2),
        (title: 'Bar', line: 6),
      ]);
    });

    test('yaml: top-level keys only, nested keys excluded', () {
      const String text = 'name: demo\n'
          'settings:\n'
          '  nested: true\n'
          '  other: false\n'
          'items:\n'
          '  - a\n'
          '  - b\n'
          'trailing: yes\n';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.yaml);
      expect(entries, <ImenuEntry>[
        (title: 'name', line: 0),
        (title: 'settings', line: 1),
        (title: 'items', line: 4),
        (title: 'trailing', line: 7),
      ]);
    });

    test('yaml: comment-only line is not indexed', () {
      const String text = '# a top-of-file comment\nreal: value\n';
      final List<ImenuEntry> entries = imenuIndex(text, SyntaxLanguage.yaml);
      expect(entries, <ImenuEntry>[(title: 'real', line: 1)]);
    });
  });
}
