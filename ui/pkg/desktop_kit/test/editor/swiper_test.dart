// Behavioural coverage for swiper's headless model — an ivy/swiper-style
// live filtered line search over the buffer (M-s s).
//
// Drives the buffer's own entry points (execute / promptChar / swiperNext /
// promptAccept / promptCancel) — the exact calls a host widget makes — so the
// filter/selection/preview state machine is exercised deterministically
// without fighting symbol-key simulation. The widget-level M-s s -> panel ->
// filter -> preview -> land wiring lives in eedit's `swiper_test.dart`.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void _type(EmacsBuffer b, String s) {
  for (final String ch in s.split('')) {
    b.promptChar(ch);
  }
}

void main() {
  group('swiper (model)', () {
    test('opening lists every line and previews near point', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nbbb\nccc', caret: 0);
      b.execute('swiper');
      expect(b.swiping, isTrue);
      expect(b.swiperCandidates.length, 3);
      expect(b.swiperSelected, 0); // point is on line 0
      expect(b.status, 'swiper: 3 matches');
    });

    test('typing filters to the matching lines (regex)', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nbbb\nccc\nbbc', caret: 0);
      b.execute('swiper');
      _type(b, 'bb');
      expect(
        b.swiperCandidates.map((SwiperLine c) => c.line).toList(),
        <int>[1, 3],
      );
      expect(b.status, 'swiper: 2 matches');
      expect(b.searchHits, isNotEmpty); // matches published for highlighting
    });

    test('swiperNext / swiperPrevious move the selection and preview point',
        () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nbbb\nccc', caret: 0);
      b.execute('swiper');
      expect(b.swiperSelected, 0);
      expect(b.caret, 0); // empty input -> line start of the selected line
      b.swiperNext();
      expect(b.swiperSelected, 1);
      expect(b.caret, 4); // 'bbb' starts at offset 4
      b.swiperPrevious();
      expect(b.swiperSelected, 0);
      b.swiperPrevious(); // wraps to the last candidate
      expect(b.swiperSelected, 2);
    });

    test('RET lands point at the selected line match start', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nbbb\nccc\nbbc', caret: 0);
      b.execute('swiper');
      _type(b, 'bb'); // candidates on lines 1 and 3; selection -> line 1
      expect(b.caret, 4); // 'bb' match start on line 1
      b.promptAccept();
      expect(b.swiping, isFalse);
      expect(b.caret, 4);
      expect(b.status, 'swiper: landed');
    });

    test('C-g restores the pre-swiper point', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nbbb\nccc', caret: 0);
      b.execute('swiper');
      b.swiperNext();
      expect(b.caret, isNot(0)); // preview moved point
      b.promptCancel();
      expect(b.swiping, isFalse);
      expect(b.caret, 0);
      expect(b.status, 'Quit');
    });

    test('an invalid regex matches literally, never throws', () {
      final EmacsBuffer b = EmacsBuffer(text: 'aaa\nx[y\nccc', caret: 0);
      b.execute('swiper');
      _type(b, '['); // unterminated class -> literal '['
      expect(
        b.swiperCandidates.map((SwiperLine c) => c.line).toList(),
        <int>[1], // only 'x[y' contains a literal '['
      );
      expect(b.status, 'swiper: 1 matches');
    });
  });
}
