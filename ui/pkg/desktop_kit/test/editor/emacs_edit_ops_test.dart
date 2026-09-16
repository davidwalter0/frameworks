// Headless tests for the pure EditOps commands. Every expectation below is
// hand-derived from the documented Emacs semantics (M-; / M-z / M-t / C-x C-t
// / M-g g / C-x r k / C-x r y), not read back off the implementation.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commentDwim', () {
    test('adds "; " to an uncommented line and carries the caret', () {
      final r = EditOps.commentDwim('hello\nworld', 2, ';');
      expect(r.text, '; hello\nworld');
      expect(r.caret, 4);
    });

    test('toggling twice is the identity', () {
      final on = EditOps.commentDwim('hello', 2, ';');
      final off = EditOps.commentDwim(on.text, on.caret, ';');
      expect(off.text, 'hello');
      expect(off.caret, 2);
    });

    test('inserts after leading indentation', () {
      final r = EditOps.commentDwim('    foo', 6, ';');
      expect(r.text, '    ; foo');
      expect(r.caret, 8);
    });

    test('caret before the indent column does not move', () {
      final r = EditOps.commentDwim('    foo', 1, ';');
      expect(r.text, '    ; foo');
      expect(r.caret, 1);
    });

    test('caret at line start ends up before the code, not before the token',
        () {
      final r = EditOps.commentDwim('int x;', 0, '//');
      expect(r.text, '// int x;');
      expect(r.caret, 3);
    });

    test('operates on the caret line only', () {
      final r = EditOps.commentDwim('a\nbb', 3, ';');
      expect(r.text, 'a\n; bb');
      expect(r.caret, 5);
    });

    test('comments an empty line', () {
      final r = EditOps.commentDwim('', 0, ';');
      expect(r.text, '; ');
      expect(r.caret, 2);
    });

    test('uncomment without a following space removes just the token', () {
      final r = EditOps.commentDwim(';foo', 4, ';');
      expect(r.text, 'foo');
      expect(r.caret, 3);
    });

    test('uncomment with the caret inside the token clamps to the indent', () {
      final r = EditOps.commentDwim('; foo', 1, ';');
      expect(r.text, 'foo');
      expect(r.caret, 0);
    });

    test('uncomment preserves indentation', () {
      final r = EditOps.commentDwim('  ; foo', 6, ';');
      expect(r.text, '  foo');
      expect(r.caret, 4);
    });

    test('an empty comment token is a no-op', () {
      final r = EditOps.commentDwim('foo', 2, '');
      expect(r.text, 'foo');
      expect(r.caret, 2);
    });
  });

  group('zapToCharKill', () {
    test('kills through the next occurrence, inclusive', () {
      final r = EditOps.zapToCharKill('hello world', 0, 'o');
      expect(r.text, ' world');
      expect(r.caret, 0);
      expect(r.killed, 'hello');
    });

    test('an occurrence at the caret kills exactly one char', () {
      final r = EditOps.zapToCharKill('xabc', 0, 'x');
      expect(r.text, 'abc');
      expect(r.caret, 0);
      expect(r.killed, 'x');
    });

    test('searches strictly forward from the caret', () {
      final r = EditOps.zapToCharKill('aXbXc', 2, 'X');
      expect(r.text, 'aXc');
      expect(r.caret, 2);
      expect(r.killed, 'bX');
    });

    test('no occurrence leaves the text alone with an empty kill', () {
      final r = EditOps.zapToCharKill('abc', 0, 'z');
      expect(r.text, 'abc');
      expect(r.caret, 0);
      expect(r.killed, '');
    });

    test('occurrence behind the caret does not count', () {
      final r = EditOps.zapToCharKill('zabc', 2, 'z');
      expect(r.text, 'zabc');
      expect(r.killed, '');
    });

    test('a multi-char target kills through its last char', () {
      final r = EditOps.zapToCharKill('foo bar baz', 0, 'bar');
      expect(r.text, ' baz');
      expect(r.killed, 'foo bar');
    });

    test('an empty target is a no-op', () {
      final r = EditOps.zapToCharKill('abc', 1, '');
      expect(r.text, 'abc');
      expect(r.caret, 1);
      expect(r.killed, '');
    });

    test('an out-of-range caret clamps to the end', () {
      final r = EditOps.zapToCharKill('abc', 99, 'a');
      expect(r.text, 'abc');
      expect(r.caret, 3);
      expect(r.killed, '');
    });

    test('kills across a newline', () {
      final r = EditOps.zapToCharKill('ab\ncd', 1, 'c');
      expect(r.text, 'ad');
      expect(r.killed, 'b\nc');
    });
  });

  group('zapToChar', () {
    test('matches zapToCharKill but drops the killed span', () {
      final r = EditOps.zapToChar('hello world', 0, 'o');
      expect(r.text, ' world');
      expect(r.caret, 0);
    });

    test('no occurrence is a no-op', () {
      final r = EditOps.zapToChar('abc', 1, 'z');
      expect(r.text, 'abc');
      expect(r.caret, 1);
    });
  });

  group('transposeWords', () {
    test('swaps the words around the caret and lands after the second', () {
      final r = EditOps.transposeWords('foo bar', 3);
      expect(r.text, 'bar foo');
      expect(r.caret, 7);
    });

    test('caret at the start of the second word works too', () {
      final r = EditOps.transposeWords('foo bar', 4);
      expect(r.text, 'bar foo');
      expect(r.caret, 7);
    });

    test('preserves the separator between the words', () {
      final r = EditOps.transposeWords('foo, bar', 4);
      expect(r.text, 'bar, foo');
      expect(r.caret, 8);
    });

    test('transposes across a newline', () {
      final r = EditOps.transposeWords('foo\nbar', 3);
      expect(r.text, 'bar\nfoo');
      expect(r.caret, 7);
    });

    test('leaves surrounding text untouched', () {
      final r = EditOps.transposeWords('a foo bar b', 5);
      expect(r.text, 'a bar foo b');
      expect(r.caret, 9);
    });

    test('no next word is a no-op', () {
      final r = EditOps.transposeWords('foo bar', 7);
      expect(r.text, 'foo bar');
      expect(r.caret, 7);
    });

    test('only trailing whitespace ahead is a no-op', () {
      final r = EditOps.transposeWords('foo   ', 3);
      expect(r.text, 'foo   ');
      expect(r.caret, 3);
    });

    test('no preceding word is a no-op', () {
      final r = EditOps.transposeWords('foo bar', 0);
      expect(r.text, 'foo bar');
      expect(r.caret, 0);
    });

    test('leading whitespace only before the word is a no-op', () {
      final r = EditOps.transposeWords('  bar baz', 0);
      expect(r.text, '  bar baz');
      expect(r.caret, 0);
    });

    test('empty text is a no-op', () {
      final r = EditOps.transposeWords('', 0);
      expect(r.text, '');
      expect(r.caret, 0);
    });
  });

  group('transposeLines', () {
    test('swaps the caret line with the one above, caret riding along', () {
      final r = EditOps.transposeLines('one\ntwo\nthree', 5);
      expect(r.text, 'two\none\nthree');
      expect(r.caret, 1);
    });

    test('first line is a no-op', () {
      final r = EditOps.transposeLines('one\ntwo', 1);
      expect(r.text, 'one\ntwo');
      expect(r.caret, 1);
    });

    test('last line swaps upward', () {
      final r = EditOps.transposeLines('a\nbb', 4);
      expect(r.text, 'bb\na');
      expect(r.caret, 2);
    });

    test('column clamps to the shorter destination line', () {
      final r = EditOps.transposeLines('abcd\nx', 6);
      expect(r.text, 'x\nabcd');
      expect(r.caret, 1);
    });

    test('handles a trailing-newline final empty line', () {
      final r = EditOps.transposeLines('a\nb\n', 4);
      expect(r.text, 'a\n\nb');
      expect(r.caret, 2);
    });

    test('single line text is a no-op', () {
      final r = EditOps.transposeLines('only', 2);
      expect(r.text, 'only');
      expect(r.caret, 2);
    });

    test('length is preserved', () {
      final r = EditOps.transposeLines('one\ntwo\nthree', 9);
      expect(r.text.length, 'one\ntwo\nthree'.length);
      expect(r.text, 'one\nthree\ntwo');
    });
  });

  group('gotoLine', () {
    const text = 'a\nbb\nccc';

    test('is 1-indexed and never changes the text', () {
      final r = EditOps.gotoLine(text, 2);
      expect(r.text, text);
      expect(r.caret, 2);
    });

    test('line 1 is offset 0', () {
      expect(EditOps.gotoLine(text, 1).caret, 0);
    });

    test('last line', () {
      expect(EditOps.gotoLine(text, 3).caret, 5);
    });

    test('clamps below range', () {
      expect(EditOps.gotoLine(text, 0).caret, 0);
      expect(EditOps.gotoLine(text, -7).caret, 0);
    });

    test('clamps above range', () {
      expect(EditOps.gotoLine(text, 99).caret, 5);
    });

    test('single-line text always lands at 0', () {
      expect(EditOps.gotoLine('abc', 5).caret, 0);
    });

    test('trailing newline yields a real final (empty) line', () {
      final r = EditOps.gotoLine('a\n', 2);
      expect(r.caret, 2);
    });

    test('empty text', () {
      expect(EditOps.gotoLine('', 3).caret, 0);
    });
  });

  group('killRectangle', () {
    const grid = 'abcdef\nghijkl\nmnopqr';

    test('removes the column span on every spanned line', () {
      // (0,1) .. (2,3) — columns [1,3) across three lines.
      final r = EditOps.killRectangle(grid, 1, 17);
      expect(r.text, 'adef\ngjkl\nmpqr');
      expect(r.rect, ['bc', 'hi', 'no']);
      expect(r.caret, 1); // Upper-left corner.
    });

    test('argument order does not matter', () {
      final a = EditOps.killRectangle(grid, 1, 17);
      final b = EditOps.killRectangle(grid, 17, 1);
      expect(b.text, a.text);
      expect(b.rect, a.rect);
      expect(b.caret, a.caret);
    });

    test('mixed corner order normalises the column span', () {
      // (0,3) .. (2,1) — still columns [1,3).
      final r = EditOps.killRectangle(grid, 3, 15);
      expect(r.text, 'adef\ngjkl\nmpqr');
      expect(r.rect, ['bc', 'hi', 'no']);
    });

    test('a single-line rectangle', () {
      final r = EditOps.killRectangle('abcdef', 1, 3);
      expect(r.text, 'adef');
      expect(r.rect, ['bc']);
      expect(r.caret, 1);
    });

    test('a zero-width rectangle changes nothing', () {
      final r = EditOps.killRectangle(grid, 1, 8);
      expect(r.text, grid);
      expect(r.rect, ['', '']);
      expect(r.caret, 1);
    });

    test('a line ending inside the rectangle contributes what it has', () {
      // 'abcdef\nxy\nmnopqr' — (0,1) .. (2,3); line 1 only reaches column 2.
      final r = EditOps.killRectangle('abcdef\nxy\nmnopqr', 1, 13);
      expect(r.text, 'adef\nx\nmpqr');
      expect(r.rect, ['bc', 'y', 'no']);
    });

    test('lines shorter than the left column contribute empty strings', () {
      // 'abcdef\n\nmnopqr' — (0,3) .. (2,5); line 1 is empty.
      final r = EditOps.killRectangle('abcdef\n\nmnopqr', 3, 13);
      expect(r.text, 'abcf\n\nmnor');
      expect(r.rect, ['de', '', 'pq']);
      expect(r.caret, 3);
    });

    test('a rectangle starting at EOL kills nothing but reports per line', () {
      final r = EditOps.killRectangle('ab\ncd', 2, 5);
      expect(r.text, 'ab\ncd');
      expect(r.rect, ['', '']);
      expect(r.caret, 2);
    });

    test('offsets clamp into range', () {
      final r = EditOps.killRectangle('abcdef', -5, 300);
      expect(r.text, '');
      expect(r.rect, ['abcdef']);
      expect(r.caret, 0);
    });
  });

  group('yankRectangle', () {
    test('re-inserts a rectangle down from the caret column', () {
      final r =
          EditOps.yankRectangle('adef\ngjkl\nmpqr', 1, ['bc', 'hi', 'no']);
      expect(r.text, 'abcdef\nghijkl\nmnopqr');
      expect(r.caret, 17); // Lower-right corner.
    });

    test('round-trips with killRectangle', () {
      const grid = 'abcdef\nghijkl\nmnopqr';
      final killed = EditOps.killRectangle(grid, 1, 17);
      final back =
          EditOps.yankRectangle(killed.text, killed.caret, killed.rect);
      expect(back.text, grid);
    });

    test('pads short lines out to the caret column', () {
      final r = EditOps.yankRectangle('abcd\nx', 3, ['1', '2']);
      expect(r.text, 'abc1d\nx  2');
      expect(r.caret, 10);
    });

    test('creates lines past the end of the text', () {
      final r = EditOps.yankRectangle('ab', 1, ['X', 'Y']);
      expect(r.text, 'aXb\n Y');
      expect(r.caret, 6);
    });

    test('yanking at end-of-line appends', () {
      final r = EditOps.yankRectangle('ab', 2, ['Z']);
      expect(r.text, 'abZ');
      expect(r.caret, 3);
    });

    test('an empty rect is a no-op', () {
      final r = EditOps.yankRectangle('ab\ncd', 1, const []);
      expect(r.text, 'ab\ncd');
      expect(r.caret, 1);
    });

    test('empty rect rows still advance the caret down', () {
      final r = EditOps.yankRectangle('ab\ncd', 1, ['', '']);
      expect(r.text, 'ab\ncd');
      expect(r.caret, 4);
    });

    test('yanking into empty text builds the lines', () {
      final r = EditOps.yankRectangle('', 0, ['a', 'b']);
      expect(r.text, 'a\nb');
      expect(r.caret, 3);
    });

    test('an out-of-range caret clamps to the end', () {
      final r = EditOps.yankRectangle('ab', 99, ['Z']);
      expect(r.text, 'abZ');
      expect(r.caret, 3);
    });
  });
}
