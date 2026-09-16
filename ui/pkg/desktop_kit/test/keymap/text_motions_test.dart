import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // _isWordChar coverage (exercised indirectly through forwardWord / backwardWord)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // forwardWord (M-f)
  // ---------------------------------------------------------------------------
  group('forwardWord', () {
    const cases = [
      // (description, text, offset, expected)
      ('empty buffer → stays at 0', '', 0, 0),
      ('at end → stays at end', 'hello', 5, 5),
      ('offset > length → clamped to end', 'hi', 99, 2),
      ('mid-word → moves to word end', 'hello world', 2, 5),
      ('at word boundary → skips space then ends', 'hello world', 5, 11),
      ('from space between words', ' hello', 0, 6),
      ('single word at start', 'hello', 0, 5),
      ('leading punctuation', '(hello)', 0, 6),
      ('underscore treated as word char', 'foo_bar baz', 0, 7),
      ('digits treated as word char', '123 456', 0, 3),
      ('mixed word+digit', 'foo2 x', 0, 4),
      ('multiple spaces before word', '   hi', 0, 5),
      ('offset clamped at 0 when negative', 'abc', -5, 3),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.forwardWord(text, offset), expected);
      });
    }

    test('high-unicode (non-ASCII) treated as word chars', () {
      // Japanese characters are > 0x7F — each counts as a word char.
      const text = 'こんにちは world';
      // forwardWord from 0 should stop after the Japanese word (5 chars).
      expect(TextMotions.forwardWord(text, 0), 5);
    });
  });

  // ---------------------------------------------------------------------------
  // backwardWord (M-b)
  // ---------------------------------------------------------------------------
  group('backwardWord', () {
    const cases = [
      ('empty buffer → stays at 0', '', 0, 0),
      ('at start → stays at 0', 'hello', 0, 0),
      ('offset > length clamped', 'hi', 99, 0),
      ('at word end → moves to word start', 'hello', 5, 0),
      ('mid-word → moves to word start', 'hello world', 8, 6),
      (
        'at space between words → goes to start of prior word',
        'hello world',
        5,
        0,
      ),
      ('single word', 'hello', 3, 0),
      ('trailing punctuation', 'hello!', 6, 0),
      ('underscore in word', 'foo_bar', 7, 0),
      ('digit-only word', '123', 3, 0),
      ('negative offset clamped to 0', 'abc', -1, 0),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.backwardWord(text, offset), expected);
      });
    }

    test('two words: backward from end of second reaches start of second', () {
      const text = 'foo bar';
      expect(TextMotions.backwardWord(text, 7), 4);
    });

    test('high-unicode chars treated as word chars backward', () {
      const text = 'hi こんにちは';
      // Cursor at end (10). Skips no non-word chars, backs over 5 Unicode chars.
      const end = text.length;
      expect(TextMotions.backwardWord(text, end), 3);
    });
  });

  // ---------------------------------------------------------------------------
  // lineStart (C-a / move-beginning-of-line)
  // ---------------------------------------------------------------------------
  group('lineStart', () {
    const singleLine = 'hello world';
    const multiLine = 'line one\nline two\nline three';

    const cases = [
      // (description, text, offset, expected)
      ('empty buffer → 0', '', 0, 0),
      ('single line, offset 0 → 0', singleLine, 0, 0),
      ('single line, mid → 0', singleLine, 5, 0),
      ('single line, end → 0', singleLine, 11, 0),
      ('second line, start of second line', multiLine, 9, 9),
      ('second line, middle of second line', multiLine, 13, 9),
      ('third line, start', multiLine, 18, 18),
      ('third line, middle', multiLine, 22, 18),
      ('third line, end', multiLine, 28, 18),
      ('offset clamped > length', singleLine, 99, 0),
      ('offset = 0 edge case', multiLine, 0, 0),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.lineStart(text, offset), expected);
      });
    }

    test('trailing newline: line after last newline starts at length', () {
      const text = 'abc\n';
      // offset at 4 (after newline) → start of empty last line = 4
      expect(TextMotions.lineStart(text, 4), 4);
    });

    // BUG #33 edge cases: the offset-level contract for C-a across the tricky
    // inputs (leading whitespace stays column 0, multi-byte / surrogate-pair
    // counting in UTF-16 units, CRLF, leading newline, caret sitting on a
    // newline). All expect the LOGICAL beginning-of-line.
    group('BUG #33 edge cases', () {
      const cases = [
        // (description, text, offset, expected)
        // leading whitespace → column 0, NOT back-to-indentation.
        ('leading spaces → col 0', '    hello', 7, 0),
        // empty middle line: a0 \n1 \n2 b3 — caret on the empty line 2.
        ('empty middle line', 'a\n\nb', 2, 2),
        // caret sitting ON the newline that ends line 1 → line-1 start (0).
        ('caret on the newline char', 'ab\ncd', 2, 0),
        // multi-byte: あ0 い1 う2 \n3 か4 き5 く6 (each kana 1 UTF-16 unit).
        ('multibyte line-2 mid', 'あいう\nかきく', 6, 4),
        ('multibyte line-2 start', 'あいう\nかきく', 4, 4),
        ('multibyte caret on newline', 'あいう\nかきく', 3, 0),
        // surrogate pair 𠮷 (U+20BB7) is 2 UTF-16 units: hi0 lo1 \n2 x3.
        ('surrogate line-2', '𠮷\nx', 3, 3),
        ('surrogate caret on newline', '𠮷\nx', 2, 0),
        // CRLF: a0 b1 c2 \r3 \n4 d5 e6 f7 — logical start of line 2 is 5.
        ('CRLF line-2', 'abc\r\ndef', 7, 5),
        ('CRLF caret on the CR', 'abc\r\ndef', 3, 0),
        // leading newline: \n0 a1 b2 c3 — caret on line 2 → start 1.
        ('leading newline line-2', '\nabc', 2, 1),
        ('leading newline empty line-1', '\nabc', 0, 0),
      ];

      for (final (desc, text, offset, expected) in cases) {
        test(desc, () {
          expect(TextMotions.lineStart(text, offset), expected);
        });
      }
    });
  });

  // ---------------------------------------------------------------------------
  // lineEnd (C-e / move-end-of-line)
  // ---------------------------------------------------------------------------
  group('lineEnd', () {
    const singleLine = 'hello world';
    const multiLine = 'line one\nline two\nline three';

    const cases = [
      ('empty buffer → 0', '', 0, 0),
      ('single line, start → end of text', singleLine, 0, 11),
      ('single line, mid → end of text', singleLine, 5, 11),
      ('single line, end → end of text', singleLine, 11, 11),
      ('first line of multiline', multiLine, 0, 8),
      ('first line mid of multiline', multiLine, 4, 8),
      ('second line start', multiLine, 9, 17),
      ('second line mid', multiLine, 13, 17),
      ('third (last) line start', multiLine, 18, 28),
      ('third (last) line end', multiLine, 28, 28),
      ('offset clamped > length', singleLine, 99, 11),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.lineEnd(text, offset), expected);
      });
    }

    test('line ending with newline: end is the newline index', () {
      const text = 'abc\ndef';
      // From offset 0, lineEnd should be 3 (the newline position).
      expect(TextMotions.lineEnd(text, 0), 3);
    });
  });

  // ---------------------------------------------------------------------------
  // forwardChar (C-f)
  // ---------------------------------------------------------------------------
  group('forwardChar', () {
    const cases = [
      ('empty buffer → 0', '', 0, 0),
      ('mid text → +1', 'hello', 2, 3),
      ('at end → stays at end', 'hello', 5, 5),
      ('large offset clamped to end', 'hi', 99, 2),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.forwardChar(text, offset), expected);
      });
    }

    test('moves across newline character', () {
      const text = 'a\nb';
      expect(TextMotions.forwardChar(text, 1), 2);
    });
  });

  // ---------------------------------------------------------------------------
  // backwardChar (C-b)
  // ---------------------------------------------------------------------------
  group('backwardChar', () {
    const cases = [
      ('empty buffer → 0', '', 0, 0),
      ('at start → stays at 0', 'hello', 0, 0),
      ('mid text → -1', 'hello', 3, 2),
      ('at end → end - 1', 'hello', 5, 4),
      ('negative offset clamped to 0', 'hi', -5, 0),
    ];

    for (final (desc, text, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.backwardChar(text, offset), expected);
      });
    }

    test('moves back across newline character', () {
      const text = 'a\nb';
      expect(TextMotions.backwardChar(text, 2), 1);
    });
  });

  // ---------------------------------------------------------------------------
  // nextLine (C-n)
  // ---------------------------------------------------------------------------
  group('nextLine', () {
    const text = 'line one\nline two\nline three';
    //            0123456789012345678901234567
    //            0        9        18

    const cases = [
      // (description, offset, expected)
      ('col 0, first line → col 0 second line', 0, 9),
      ('col 4, first line → col 4 second line', 4, 13),
      ('col 0, second line → col 0 third line', 9, 18),
      ('col 4, second line → col 4 third line', 13, 22),
      // on last line → end of text
      ('on last line → end of text', 18, 28),
      ('end of text → stays at end', 28, 28),
    ];

    for (final (desc, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.nextLine(text, offset), expected);
      });
    }

    test('empty buffer → stays at 0', () {
      expect(TextMotions.nextLine('', 0), 0);
    });

    test('column beyond short next line is clamped to that line end', () {
      // 'long line\nab'
      // col 8 on first line → but second line only has 2 chars ('a' at 10,
      // 'b' at 11) → lineEnd returns text.length = 12, so target clamps to 12.
      const t = 'long line\nab';
      expect(TextMotions.nextLine(t, 8), 12);
    });

    test('single line text → end of text', () {
      expect(TextMotions.nextLine('hello', 2), 5);
    });
  });

  // ---------------------------------------------------------------------------
  // previousLine (C-p)
  // ---------------------------------------------------------------------------
  group('previousLine', () {
    const text = 'line one\nline two\nline three';

    const cases = [
      // (description, offset, expected)
      ('col 0, second line → col 0 first line', 9, 0),
      ('col 4, second line → col 4 first line', 13, 4),
      ('col 0, third line → col 0 second line', 18, 9),
      ('col 4, third line → col 4 second line', 22, 13),
      // on first line → stays at 0
      ('on first line → 0', 4, 0),
      ('at offset 0 → stays at 0', 0, 0),
    ];

    for (final (desc, offset, expected) in cases) {
      test(desc, () {
        expect(TextMotions.previousLine(text, offset), expected);
      });
    }

    test('empty buffer → stays at 0', () {
      expect(TextMotions.previousLine('', 0), 0);
    });

    test('column beyond short previous line is clamped to that line end', () {
      // 'ab\nlong line here'
      // col 8 on second line → but first line only has 2 chars → clamp to 2
      const t = 'ab\nlong line here';
      expect(TextMotions.previousLine(t, 11), 2);
    });

    test('single line text → stays at 0', () {
      expect(TextMotions.previousLine('hello', 3), 0);
    });
  });

  // ---------------------------------------------------------------------------
  // killLineSpan (C-k)
  // ---------------------------------------------------------------------------
  group('killLineSpan', () {
    const cases = [
      // (description, text, offset, expectedStart, expectedEnd)
      ('empty buffer → [0, 0] nothing to kill', '', 0, 0, 0),
      ('mid-line → [offset, eol]', 'hello world', 2, 2, 11),
      ('at start of line → [0, eol]', 'hello world', 0, 0, 11),
      (
        'at eol with following newline → deletes newline',
        'hello\nworld',
        5,
        5,
        6,
      ),
      ('at end of last line (no newline) → [end, end]', 'hello', 5, 5, 5),
    ];

    for (final (desc, text, offset, expectedStart, expectedEnd) in cases) {
      test(desc, () {
        final span = TextMotions.killLineSpan(text, offset);
        expect(span, [expectedStart, expectedEnd]);
      });
    }

    test(
      'from col 0 on first of multi-line: kills through newline boundary',
      () {
        const text = 'abc\ndef';
        // At offset 0, eol=3 (the newline index), eol > 0 → span [0, 3]
        final span = TextMotions.killLineSpan(text, 0);
        expect(span, [0, 3]);
      },
    );

    test('at newline char itself → removes the newline joining lines', () {
      const text = 'abc\ndef';
      // offset = 3 (at the '\n'), eol = lineEnd(text, 3) = 3, eol == offset
      // so next branch: eol < text.length → [3, 4]
      final span = TextMotions.killLineSpan(text, 3);
      expect(span, [3, 4]);
    });

    test('large offset clamped to length → nothing to kill', () {
      const text = 'hello';
      final span = TextMotions.killLineSpan(text, 99);
      expect(span, [5, 5]);
    });
  });

  // ---------------------------------------------------------------------------
  // deleteCharSpan (C-d)
  // ---------------------------------------------------------------------------
  group('deleteCharSpan', () {
    const cases = [
      // (description, text, offset, expectedStart, expectedEnd)
      ('empty buffer → [0, 0]', '', 0, 0, 0),
      ('at start → [0, 1]', 'hello', 0, 0, 1),
      ('mid text → [offset, offset+1]', 'hello', 3, 3, 4),
      ('at end → [end, end] nothing to delete', 'hello', 5, 5, 5),
      ('large offset clamped → [end, end]', 'hi', 99, 2, 2),
      ('negative offset clamped → [0, 1]', 'hi', -5, 0, 1),
    ];

    for (final (desc, text, offset, expectedStart, expectedEnd) in cases) {
      test(desc, () {
        final span = TextMotions.deleteCharSpan(text, offset);
        expect(span, [expectedStart, expectedEnd]);
      });
    }

    test('deletes newline char', () {
      const text = 'a\nb';
      final span = TextMotions.deleteCharSpan(text, 1);
      expect(span, [1, 2]);
    });
  });

  // ---------------------------------------------------------------------------
  // Round-trip / composed motion tests
  // ---------------------------------------------------------------------------
  group('composed motions', () {
    test('forwardWord then backwardWord returns to original offset', () {
      const text = 'hello world foo';
      const offset = 0;
      final fwd = TextMotions.forwardWord(text, offset);
      final back = TextMotions.backwardWord(text, fwd);
      expect(back, offset);
    });

    test('forwardChar then backwardChar returns to original', () {
      const text = 'hello';
      const offset = 2;
      final fwd = TextMotions.forwardChar(text, offset);
      final back = TextMotions.backwardChar(text, fwd);
      expect(back, offset);
    });

    test('nextLine then previousLine returns to same line start region', () {
      const text = 'abc\ndef\nghi';
      // Start at col 1 of line 0 (offset 1).
      final down = TextMotions.nextLine(text, 1);
      final up = TextMotions.previousLine(text, down);
      expect(up, 1); // back to col 1 of first line
    });

    test('lineStart + lineEnd covers the full first line', () {
      const text = 'hello\nworld';
      final start = TextMotions.lineStart(text, 3);
      final end = TextMotions.lineEnd(text, 3);
      expect(text.substring(start, end), 'hello');
    });

    test('killLineSpan applied repeatedly drains a two-line buffer', () {
      // Simulate two C-k presses on 'abc\ndef'.
      const text = 'abc\ndef';
      // First C-k at offset 0: span [0,3] → kill 'abc', text becomes '\ndef'.
      // (We don't actually mutate; just verify spans are correct and ordered.)
      final span1 = TextMotions.killLineSpan(text, 0);
      expect(span1, [0, 3]); // 'abc'

      // After removing [0,3] the text would be '\ndef'; next C-k at offset 0
      // → eol=0, eol < length → [0,1] removes the newline.
      const text2 = '\ndef';
      final span2 = TextMotions.killLineSpan(text2, 0);
      expect(span2, [0, 1]);

      // After removing [0,1] the text would be 'def'; next C-k at offset 0
      // → eol=3, eol > 0 → [0,3] kills the rest.
      const text3 = 'def';
      final span3 = TextMotions.killLineSpan(text3, 0);
      expect(span3, [0, 3]);
    });

    test('word motions skip punctuation-only tokens', () {
      // "(foo) (bar)" — M-f from 0 skips '(' and lands after 'foo' at 4.
      // M-f from 4 skips ')', ' ', '(' and then consumes 'bar' (indices 7-9),
      // landing at 10 (one past 'r').
      const text = '(foo) (bar)';
      expect(TextMotions.forwardWord(text, 0), 4);
      expect(TextMotions.forwardWord(text, 4), 10);
    });

    test('nextLine on trailing-newline text moves into empty last line', () {
      const text = 'abc\n';
      // From offset 0, eol=3, nextStart=4, nextEol=4, target=0+0=4 → 4
      final result = TextMotions.nextLine(text, 0);
      expect(result, 4);
    });

    test('previousLine column 0 always reaches column 0 of prior line', () {
      const text = 'alpha\nbeta';
      // At start of 'beta' (offset 6), col=0, prevEol=5, prevStart=0
      // target=0+0=0, 0 <= 5 → 0
      expect(TextMotions.previousLine(text, 6), 0);
    });
  });
}
