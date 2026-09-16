import 'package:desktop_kit/desktop_kit_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

/// Asserts the two structural invariants every language must uphold:
/// spans are sorted by start and never overlap.
void expectWellFormed(List<FaceSpan> spans, String text) {
  for (int i = 0; i < spans.length; i++) {
    expect(spans[i].start < spans[i].end, isTrue,
        reason: 'span $i is empty or inverted: '
            '${spans[i].start}-${spans[i].end}');
    expect(spans[i].start >= 0 && spans[i].end <= text.length, isTrue,
        reason: 'span $i is out of bounds: ${spans[i].start}-${spans[i].end} '
            'for text of length ${text.length}');
    if (i > 0) {
      expect(spans[i].start >= spans[i - 1].start, isTrue,
          reason: 'spans are not sorted by start at $i');
      expect(spans[i].start >= spans[i - 1].end, isTrue,
          reason: 'spans ${i - 1} and $i overlap: '
              '${spans[i - 1].start}-${spans[i - 1].end} vs '
              '${spans[i].start}-${spans[i].end}');
    }
  }
}

/// The substrings tagged with [face], in document order.
List<String> textsFor(List<FaceSpan> spans, String text, String face) => spans
    .where((FaceSpan s) => s.face == face)
    .map((FaceSpan s) => text.substring(s.start, s.end))
    .toList();

void main() {
  group('SyntaxLanguage.none', () {
    test('never produces a span', () {
      expect(SyntaxFaces.spans('', SyntaxLanguage.none), isEmpty);
      expect(
        SyntaxFaces.spans(
          '(defun f) ; c\nfunc g() {}\n* head\nkey: true\n',
          SyntaxLanguage.none,
        ),
        isEmpty,
      );
    });
  });

  group('empty text', () {
    for (final SyntaxLanguage lang in SyntaxLanguage.values) {
      test('yields no spans for $lang', () {
        expect(SyntaxFaces.spans('', lang), isEmpty);
      });
    }
  });

  group('SyntaxFaces.spans — elisp', () {
    test('tags a line comment to end of line', () {
      const String text = 'x = 1 ; a trailing comment';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      final FaceSpan comment =
          spans.firstWhere((s) => s.face == 'font-lock-comment-face');
      expect(comment.start, text.indexOf(';'));
      expect(comment.end, text.length);
    });

    test('tags a double-quoted string', () {
      const String text = 'let s = "hello world";';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      final FaceSpan string =
          spans.firstWhere((s) => s.face == 'font-lock-string-face');
      expect(text.substring(string.start, string.end), '"hello world"');
    });

    test('tags keywords from the elisp set', () {
      const String text = 'if (x) { let y = 1; }';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      expect(textsFor(spans, text, 'font-lock-keyword-face'),
          containsAll(<String>['if', 'let']));
    });

    test('tags the function name after "defun "', () {
      const String text = '(defun my-command (arg) (message arg))';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      expect(textsFor(spans, text, 'font-lock-function-name-face'),
          contains('my-command'));
    });

    test('tags the function name after an opening paren', () {
      const String text = '(message "hi")';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      final FaceSpan fn =
          spans.firstWhere((s) => s.face == 'font-lock-function-name-face');
      expect(text.substring(fn.start, fn.end), 'message');
    });

    test('a keyword inside a string is not a keyword', () {
      const String text = '(setq s "if let lambda")';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      expect(textsFor(spans, text, 'font-lock-keyword-face'), <String>['setq']);
      expect(textsFor(spans, text, 'font-lock-string-face'),
          <String>['"if let lambda"']);
    });

    test('comment takes precedence over string when overlapping', () {
      // The `;` starts a comment that swallows what would otherwise look
      // like the start of a string literal.
      const String text = 'x = 1 ; "not really a string"';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      final FaceSpan comment =
          spans.firstWhere((s) => s.face == 'font-lock-comment-face');
      expect(comment.start, text.indexOf(';'));
      expect(comment.end, text.length);
      expect(spans.any((s) => s.face == 'font-lock-string-face'), isFalse);
    });

    test('spans are well-formed', () {
      const String text = '(defun greet (name) ; say hello, if you must\n'
          '  (message "hi %s, let\'s go" name))';
      final List<FaceSpan> spans =
          SyntaxFaces.spans(text, SyntaxLanguage.elisp);
      expectWellFormed(spans, text);
    });
  });

  group('SyntaxFaces.spans — go', () {
    test('tags a // comment to end of line', () {
      const String text = 'x := 1 // a trailing comment\ny := 2';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      final FaceSpan comment =
          spans.firstWhere((s) => s.face == 'font-lock-comment-face');
      expect(comment.start, text.indexOf('//'));
      expect(comment.end, text.indexOf('\n'));
    });

    test('tags a block comment across lines', () {
      const String text = 'a\n/* block\n   comment */\nb';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(textsFor(spans, text, 'font-lock-comment-face'),
          <String>['/* block\n   comment */']);
    });

    test('tags double-quoted and backquoted raw strings', () {
      const String text = 'a := "hi"\nb := `raw\nstring`';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(textsFor(spans, text, 'font-lock-string-face'),
          <String>['"hi"', '`raw\nstring`']);
    });

    test('tags keywords', () {
      const String text = 'package main\nimport "fmt"\n'
          'func f() { for range x { if y {} else {} }; return }';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(
        textsFor(spans, text, 'font-lock-keyword-face'),
        containsAll(<String>[
          'package',
          'import',
          'func',
          'for',
          'range',
          'if',
          'else',
          'return',
        ]),
      );
    });

    test('tags builtin type names', () {
      const String text = 'var a int64 = 1; var b string; var c error; '
          'var d any; var e float64';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(
        textsFor(spans, text, 'font-lock-type-face'),
        containsAll(<String>['int64', 'string', 'error', 'any', 'float64']),
      );
    });

    test('tags the identifier right after func', () {
      const String text = 'func Serve(addr string) error { return nil }';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(textsFor(spans, text, 'font-lock-function-name-face'),
          <String>['Serve']);
      // ...and `func` itself stays a keyword, not part of the name.
      expect(textsFor(spans, text, 'font-lock-keyword-face'),
          containsAll(<String>['func', 'return']));
    });

    test('a keyword or type inside a string is neither', () {
      const String text = 'msg := "func for return int64"';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(spans.any((s) => s.face == 'font-lock-keyword-face'), isFalse);
      expect(spans.any((s) => s.face == 'font-lock-type-face'), isFalse);
      expect(textsFor(spans, text, 'font-lock-string-face'),
          <String>['"func for return int64"']);
    });

    test('a keyword inside a comment is not a keyword', () {
      const String text = '// func f() string { return "x" }';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(textsFor(spans, text, 'font-lock-comment-face'), <String>[text]);
      expect(spans.any((s) => s.face == 'font-lock-keyword-face'), isFalse);
      expect(spans.any((s) => s.face == 'font-lock-string-face'), isFalse);
    });

    test('comment takes precedence over a string it swallows', () {
      const String text = 'x := 1 // "not really a string"';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expect(spans.any((s) => s.face == 'font-lock-string-face'), isFalse);
    });

    test('spans are well-formed', () {
      const String text = 'package main\n\n'
          '/* doc */\n'
          '// Serve runs the server for a while.\n'
          'func Serve(addr string) error {\n'
          '  const greeting = "hi func, if you range"\n'
          '  var raw = `raw // not a comment`\n'
          '  for i := 0; i < 3; i++ { defer close(ch) }\n'
          '  return nil\n'
          '}\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.go);
      expectWellFormed(spans, text);
    });
  });

  group('SyntaxFaces.spans — org', () {
    test('tags a # line comment', () {
      const String text = '# a comment\ntext';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'font-lock-comment-face'),
          <String>['# a comment']);
    });

    test('tags heading levels 1-3 distinctly', () {
      const String text = '* one\n** two\n*** three\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'org-level-1'), <String>['* one']);
      expect(textsFor(spans, text, 'org-level-2'), <String>['** two']);
      expect(textsFor(spans, text, 'org-level-3'), <String>['*** three']);
    });

    test('tags a block from #+begin_ to #+end_', () {
      const String text = '#+begin_src sh\necho hi\n#+end_src\nafter';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      // The begin/end delimiter lines are claimed by 'org-meta-line' (higher
      // precedence than 'org-block'), so the block face is left covering only
      // the body between them.
      expect(textsFor(spans, text, 'org-block'), <String>['\necho hi\n']);
      // A `#+` keyword line is org syntax, not a `#` comment.
      expect(spans.any((s) => s.face == 'font-lock-comment-face'), isFalse);
    });

    test('tags the #+begin_/#+end_ delimiter lines as org-meta-line', () {
      const String text = '#+begin_src sh\necho hi\n#+end_src\nafter';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'org-meta-line'),
          <String>['#+begin_src sh', '#+end_src']);
    });

    test('tags verbatim and code markup', () {
      const String text = 'see =verbatim= and ~code~ here';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(
          textsFor(spans, text, 'org-code'), <String>['=verbatim=', '~code~']);
    });

    test('tags links in both bare and described forms', () {
      const String text = '[[https://example.com]] and [[file:x.org][desc]]';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'org-link'),
          <String>['[[https://example.com]]', '[[file:x.org][desc]]']);
    });

    test('tags TODO and DONE keywords', () {
      const String text = 'TODO write it\nDONE shipped it';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'org-todo'), <String>['TODO']);
      expect(textsFor(spans, text, 'org-done'), <String>['DONE']);
    });

    test('a TODO keyword in a headline wins over the heading face', () {
      const String text = '* TODO buy milk';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'org-todo'), <String>['TODO']);
      // The headline still paints around the keyword, without overlapping it.
      expect(spans.any((s) => s.face == 'org-level-1'), isTrue);
      expectWellFormed(spans, text);
    });

    test('a heading marker inside a comment is not a heading', () {
      const String text = '# * not a heading, ~not code~';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expect(textsFor(spans, text, 'font-lock-comment-face'), <String>[text]);
      expect(spans.any((s) => s.face == 'org-level-1'), isFalse);
      expect(spans.any((s) => s.face == 'org-code'), isFalse);
    });

    test('spans are well-formed', () {
      const String text = '# a comment\n'
          '* TODO one [[https://example.com][link]]\n'
          '** DONE two with =verbatim=\n'
          '*** three with ~code~\n'
          '#+begin_src sh\n'
          '# inside the block\n'
          'echo hi\n'
          '#+end_src\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.org);
      expectWellFormed(spans, text);
    });
  });

  group('SyntaxFaces.spans — yaml', () {
    test('tags a # comment to end of line', () {
      const String text = 'key: 1 # a trailing comment\nother: 2';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      final FaceSpan comment =
          spans.firstWhere((s) => s.face == 'font-lock-comment-face');
      expect(comment.start, text.indexOf('#'));
      expect(comment.end, text.indexOf('\n'));
    });

    test('tags quoted strings', () {
      const String text = "a: \"double\"\nb: 'single'";
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expect(textsFor(spans, text, 'font-lock-string-face'),
          <String>['"double"', "'single'"]);
    });

    test('tags a key at line start as a variable name', () {
      const String text = 'name: gadget\nnested:\n  inner: 1\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expect(textsFor(spans, text, 'font-lock-variable-name-face'),
          <String>['name', 'nested', 'inner']);
    });

    test('tags booleans, null and bare numbers as constants', () {
      const String text = 'a: true\nb: false\nc: null\n'
          'd: yes\ne: no\nf: 8080\ng: 1.5\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expect(
        textsFor(spans, text, 'font-lock-constant-face'),
        containsAll(
            <String>['true', 'false', 'null', 'yes', 'no', '8080', '1.5']),
      );
    });

    test('a constant inside a string is not a constant', () {
      const String text = 'a: "true false 42"';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expect(spans.any((s) => s.face == 'font-lock-constant-face'), isFalse);
      expect(textsFor(spans, text, 'font-lock-string-face'),
          <String>['"true false 42"']);
    });

    test('a key-looking word inside a comment is not a variable name', () {
      const String text = '# disabled: true';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expect(textsFor(spans, text, 'font-lock-comment-face'), <String>[text]);
      expect(
          spans.any((s) => s.face == 'font-lock-variable-name-face'), isFalse);
      expect(spans.any((s) => s.face == 'font-lock-constant-face'), isFalse);
    });

    test('spans are well-formed', () {
      const String text = '# config\n'
          'name: "gadget"\n'
          'enabled: true\n'
          'port: 8080\n'
          'ratio: 1.5\n'
          'empty: null\n'
          'items:\n'
          '  - first: yes # inline comment\n'
          '  - second: no\n';
      final List<FaceSpan> spans = SyntaxFaces.spans(text, SyntaxLanguage.yaml);
      expectWellFormed(spans, text);
    });
  });

  group('faceToThemeSlot', () {
    test('maps the original faces to their existing slots', () {
      expect(faceToThemeSlot('default'), 'onSurface');
      expect(faceToThemeSlot('region'), 'primary');
      expect(faceToThemeSlot('font-lock-keyword-face'), 'primary');
      expect(faceToThemeSlot('font-lock-string-face'), 'tertiary');
      expect(faceToThemeSlot('font-lock-comment-face'), 'onSurfaceVariant');
      expect(faceToThemeSlot('font-lock-function-name-face'), 'secondary');
      expect(faceToThemeSlot('cursor'), 'error');
    });

    test('maps the go/yaml font-lock faces', () {
      expect(faceToThemeSlot('font-lock-type-face'), 'tertiary');
      expect(faceToThemeSlot('font-lock-variable-name-face'), 'secondary');
      expect(faceToThemeSlot('font-lock-constant-face'), 'tertiary');
    });

    test('maps the org faces', () {
      expect(faceToThemeSlot('org-level-1'), 'primary');
      expect(faceToThemeSlot('org-level-2'), 'secondary');
      expect(faceToThemeSlot('org-level-3'), 'tertiary');
      expect(faceToThemeSlot('org-block'), 'onSurfaceVariant');
      expect(faceToThemeSlot('org-code'), 'tertiary');
      expect(faceToThemeSlot('org-link'), 'primary');
      expect(faceToThemeSlot('org-todo'), 'error');
      expect(faceToThemeSlot('org-done'), 'onSurfaceVariant');
    });

    test('every emitted face maps to a slot', () {
      const String sample = '(defun f (x) ; c\n  (message "hi"))\n'
          'func Serve(a string) error { return nil } // c\n'
          '* TODO one\n** DONE two\n=v= ~c~ [[l]]\n'
          '#+begin_src sh\necho\n#+end_src\n'
          'key: true # c\n';
      for (final SyntaxLanguage lang in SyntaxLanguage.values) {
        for (final FaceSpan span in SyntaxFaces.spans(sample, lang)) {
          expect(faceToThemeSlot(span.face), isNotNull,
              reason: '$lang emitted unmapped face "${span.face}"');
        }
      }
    });

    test('returns null for an unmapped face', () {
      expect(faceToThemeSlot('font-lock-warning-face'), isNull);
      expect(faceToThemeSlot(''), isNull);
    });
  });
}
