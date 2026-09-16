// Headless model coverage for the tier-3 search features:
//   * regexp isearch (C-M-s / C-M-r) — live incremental regex hits, and an
//     invalid pattern that surfaces an error instead of crashing;
//   * INTERACTIVE query-replace (M-%) and query-replace-regexp (C-M-%) — the
//     per-match y/n/!/q walk, driven through the pure [EmacsBuffer] input
//     methods (execute / promptChar / promptAccept / queryReplaceRespond),
//     asserting buffer text after every decision.
//
// The chord -> prompt -> walk -> buffer widget wiring is covered by eedit's
// own `query_replace_interactive_test.dart` (package:eedit).
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feed a whole minibuffer string (from / with / pattern) then commit with RET.
void _promptString(EmacsBuffer b, String s) {
  for (final String ch in s.split('')) {
    b.promptChar(ch);
  }
  b.promptAccept();
}

/// Drive a complete literal query-replace up to the y/n/!/q phase.
EmacsBuffer _startLiteralQR(String text, String from, String with_) {
  final EmacsBuffer b = EmacsBuffer(text: text, caret: 0);
  b.execute('queryReplace');
  _promptString(b, from);
  _promptString(b, with_);
  return b;
}

void main() {
  // ────────────────────────────────────────────────────────── model: isearch
  group('regexp isearch (model)', () {
    test('C-M-s finds a regex match and moves point past it', () {
      final EmacsBuffer b = EmacsBuffer(text: 'foo bar123 baz', caret: 0);
      b.execute('isearchForwardRegexp');
      for (final String ch in r'\d+'.split('')) {
        b.promptChar(ch);
      }
      expect(b.isearching, isTrue);
      expect(b.searchHits, isNotEmpty);
      // '123' spans [7,10); forward isearch leaves point at the match end.
      expect(b.caret, 10);
      expect(b.status, contains(r'\d+'));
      expect(b.status, isNot(contains('Failing')));
    });

    test('C-M-r scans backwards to the earlier match', () {
      final EmacsBuffer b = EmacsBuffer(text: 'a1 b2 c3', caret: 8);
      b.execute('isearchBackwardRegexp');
      for (final String ch in r'\d'.split('')) {
        b.promptChar(ch);
      }
      // Backward isearch lands point on the match start of the last digit ('3').
      expect(b.caret, 7);
      expect(b.searchHits.length, 3);
    });

    test('an invalid regexp surfaces an error, never throws or moves point',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'abc', caret: 1);
      b.execute('isearchForwardRegexp');
      b.promptChar('['); // an unterminated character class
      expect(b.status, contains('Invalid regexp'));
      expect(b.searchHits, isEmpty);
      expect(b.caret, 1); // point unchanged on a bad pattern
    });
  });

  // ─────────────────────────────────────────────── model: interactive replace
  group('interactive query-replace (model)', () {
    test('y / n / y / q walk edits the buffer one match at a time', () {
      final EmacsBuffer b = _startLiteralQR('a a a a', 'a', 'X');
      expect(b.queryReplacing, isTrue);
      expect(b.queryReplacePrompt, contains('(y)es (n)ext (!)all (q)uit'));

      b.queryReplaceRespond('y');
      expect(b.text, 'X a a a');

      b.queryReplaceRespond('n'); // skip the 2nd 'a'
      expect(b.text, 'X a a a');

      b.queryReplaceRespond('y'); // replace the 3rd 'a'
      expect(b.text, 'X a X a');

      b.queryReplaceRespond('q');
      expect(b.queryReplacing, isFalse);
      expect(b.text, 'X a X a');
      expect(b.status, contains('Replaced 2 occurrences'));
    });

    test('space is a synonym for y', () {
      final EmacsBuffer b = _startLiteralQR('a a', 'a', 'X');
      b.queryReplaceRespond(' ');
      expect(b.text, 'X a');
    });

    test('! replaces the current match and every remaining one', () {
      final EmacsBuffer b = _startLiteralQR('a a a a', 'a', 'X');
      b.queryReplaceRespond('!');
      expect(b.queryReplacing, isFalse);
      expect(b.text, 'X X X X');
      expect(b.status, contains('Replaced 4 occurrences'));
    });

    test('q before any replacement leaves the buffer and undo untouched', () {
      final EmacsBuffer b = _startLiteralQR('a a a', 'a', 'X');
      expect(b.canUndo, isFalse);
      b.queryReplaceRespond('q');
      expect(b.text, 'a a a');
      expect(b.canUndo, isFalse); // no undo step recorded for a no-op walk
    });

    test('a whole query-replace collapses to a single undo step', () {
      final EmacsBuffer b = _startLiteralQR('a a a a', 'a', 'X');
      b.queryReplaceRespond('!');
      expect(b.text, 'X X X X');
      expect(b.canUndo, isTrue);
      b.execute('undo');
      expect(b.text, 'a a a a'); // one undo restores the original
    });

    test('no occurrences reports without entering the walk', () {
      final EmacsBuffer b = _startLiteralQR('hello', 'zzz', 'X');
      expect(b.queryReplacing, isFalse);
      expect(b.status, contains('No occurrences'));
    });
  });

  // ──────────────────────────────────────── model: regexp query-replace groups
  group('query-replace-regexp capture groups (model)', () {
    test('C-M-% substitutes \$1/\$2 back-references per match', () {
      final EmacsBuffer b = EmacsBuffer(text: 'a=1 b=2', caret: 0);
      b.execute('queryReplaceRegexp');
      _promptString(b, r'(\w+)=(\w+)');
      _promptString(b, r'$2=$1');
      expect(b.queryReplacing, isTrue);

      b.queryReplaceRespond('y');
      expect(b.text, '1=a b=2');

      b.queryReplaceRespond('y');
      expect(b.text, '1=a 2=b');
      expect(b.queryReplacing, isFalse);
    });

    test('an invalid regexp aborts the query-replace with an error status', () {
      final EmacsBuffer b = EmacsBuffer(text: 'abc', caret: 0);
      b.execute('queryReplaceRegexp');
      _promptString(b, '(');
      _promptString(b, 'X');
      expect(b.queryReplacing, isFalse);
      expect(b.status, contains('Invalid regexp'));
    });
  });
}
