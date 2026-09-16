import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MarkState', () {
    test('no mark by default', () {
      final m = MarkState();
      expect(m.hasMark, isFalse);
      expect(m.region(5), isNull);
    });

    test('set-mark then region spans [min,max] of mark and point', () {
      final m = MarkState();
      m.setMark(3);
      // point after the mark.
      expect(m.region(8), const Region(3, 8));
      // point before the mark — normalized.
      expect(m.region(1), const Region(1, 3));
    });

    test('region at the mark is empty', () {
      final m = MarkState();
      m.setMark(4);
      expect(m.region(4), const Region(4, 4));
      expect(m.region(4)!.isEmpty, isTrue);
    });

    test('set-mark then kill-region: region drives the deletion span', () {
      // Models the C-SPC ... C-w flow: set mark at 2, move point to 7, the
      // region [2,7) is what kill-region removes.
      final m = MarkState();
      m.setMark(2);
      final region = m.region(7);
      expect(region, const Region(2, 7));
      expect(region!.length, 5);
    });

    test('exchange-point-and-mark swaps and returns old mark', () {
      final m = MarkState();
      m.setMark(2);
      // C-x C-x with point at 9: caret should jump to old mark (2), and the
      // new mark becomes the old point (9).
      final newPoint = m.exchange(9);
      expect(newPoint, 2);
      expect(m.mark, 9);
    });

    test('exchange with no mark is a no-op', () {
      final m = MarkState();
      expect(m.exchange(5), isNull);
      expect(m.hasMark, isFalse);
    });

    test('clear removes the mark', () {
      final m = MarkState();
      m.setMark(1);
      m.clear();
      expect(m.hasMark, isFalse);
    });

    test('adjustForEdit shifts a mark after an insertion before it', () {
      final m = MarkState();
      m.setMark(10);
      // 3 chars inserted at offset 4 (before the mark).
      m.adjustForEdit(4, 3);
      expect(m.mark, 13);
    });

    test('adjustForEdit shifts a mark after a deletion before it', () {
      final m = MarkState();
      m.setMark(10);
      // 2 chars deleted at offset 3.
      m.adjustForEdit(3, -2);
      expect(m.mark, 8);
    });

    test('adjustForEdit leaves a mark before the edit point untouched', () {
      final m = MarkState();
      m.setMark(2);
      m.adjustForEdit(5, 4);
      expect(m.mark, 2);
    });
  });
}
