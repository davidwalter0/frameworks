// The mark is buffer-local, like text and caret.
//
// There used to be ONE MarkState on the model. Two consequences, both
// reported: switching buffers destroyed the mark (the switch cleared it,
// because a mark from the old buffer would otherwise describe a region in the
// new one), and while it was set, every window computed its region from it —
// so the same character offsets appeared selected in two windows showing
// different buffers.
//
// The mark now lives on Buffer. `markForBuffer` / `regionForBuffer` let a
// window ask about the buffer it actually paints instead of the current one.
//
// `lastYankRange` moves with it: the kill ring is global, but that range is a
// pair of OFFSETS INTO ONE TEXT, so a yank-pop must not act on a range
// recorded in another buffer.
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:desktop_kit/src/keymap/mark_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two buffers of different length and line count, current = *scratch*.
/// Equal-shaped fixtures let an offset from the wrong buffer look plausible.
EmacsBuffer _two() {
  final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-ONE-LINE');
  b.newBuffer('notes');
  b.insert('n1\nn2\nn3\nn4\nn5');
  b.switchToBuffer(b.bufferNames.first);
  return b;
}

void main() {
  group('the mark survives a buffer switch', () {
    test('set in A, still set in A after a round trip through B', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.caret = 0;
      expect(b.execute('setMark'), isTrue);
      b.caret = 7;
      final Region? before = b.region;
      expect(before, isNotNull);

      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);

      expect(b.mark.hasMark, isTrue,
          reason: 'switching away and back must not destroy the mark');
      expect(b.region?.start, before!.start);
      expect(b.region?.end, before.end);
    });

    test('exchange-point-and-mark still works after a round trip', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.caret = 2;
      expect(b.execute('setMark'), isTrue);
      b.caret = 9;

      b.switchToBuffer('notes');
      b.switchToBuffer(scratch);

      expect(b.execute('exchangePointAndMark'), isTrue);
      expect(b.caret, 2, reason: 'point goes to where the mark was');
    });
  });

  group('marks in different buffers are independent', () {
    test('setting a mark in B leaves A\'s mark alone', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.caret = 0;
      b.execute('setMark');
      b.caret = 5;

      b.switchToBuffer('notes');
      b.caret = 3;
      b.execute('setMark');
      b.caret = 11;
      final Region? notesRegion = b.region;

      b.switchToBuffer(scratch);

      expect(b.region!.start, 0);
      expect(b.region!.end, 5);
      expect(notesRegion!.end, 11,
          reason: "notes kept its own region, and it is not scratch's");
    });

    test('a window can read the mark of a buffer that is not current', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.switchToBuffer('notes');
      b.caret = 0;
      b.execute('setMark');
      b.caret = 8;

      b.switchToBuffer(scratch);

      // The current buffer has no mark; notes does. A window painting notes
      // must see notes' region, and one painting scratch must see none.
      expect(b.mark.hasMark, isFalse);
      expect(b.region, isNull);
      expect(b.markForBuffer('notes')!.hasMark, isTrue);
      expect(b.regionForBuffer('notes')!.start, 0);
      expect(b.regionForBuffer('notes')!.end, 8);
      expect(b.regionForBuffer(scratch), isNull);
      expect(b.markForBuffer('no-such-buffer'), isNull);
    });

    test('regionForBuffer pairs a mark with ITS OWN caret', () {
      // The failure this pins: pairing notes' mark with the current buffer's
      // caret. scratch is shorter than notes, so a mixed pair would produce a
      // region that is short, reversed, or out of range — all of which paint
      // as *something*, which is why it needs asserting rather than eyeballing.
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      b.switchToBuffer('notes');
      b.caret = 0;
      b.execute('setMark');
      b.caret = 14; // beyond the length of scratch
      b.switchToBuffer(scratch);
      b.caret = 1;

      expect(b.regionForBuffer('notes')!.end, 14,
          reason: 'the region must use notes\' caret, not the current one');
    });
  });

  group('lastYankRange is buffer-local', () {
    test('yank in A, switch to B, yank-pop does not edit B at the A range', () {
      final EmacsBuffer b = _two();
      final String scratch = b.currentBuffer;

      // Two entries so yank-pop has something to rotate to.
      b.caret = 0;
      b.execute('setMark');
      b.caret = b.text.length;
      b.execute('killRegion');
      b.insert('AAAA');
      b.caret = 0;
      b.execute('setMark');
      b.caret = 4;
      b.execute('killRegion');

      b.execute('yank');
      final String afterYank = b.text;
      expect(afterYank, isNotEmpty);

      b.switchToBuffer('notes');
      final String notesBefore = b.text;
      final bool popped = b.execute('yankPop');

      expect(popped, isTrue, reason: 'the intent is still recognised');
      expect(b.text, notesBefore,
          reason: 'no yank has happened IN THIS BUFFER, so yank-pop has no '
              'range here and must not splice at one recorded elsewhere');

      b.switchToBuffer(scratch);
      expect(b.text, afterYank, reason: "A's text was not touched either");
    });
  });
}
