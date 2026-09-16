import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NarrowState', () {
    test('starts inactive with null bounds and empty hidden set', () {
      final NarrowState state = NarrowState();
      expect(state.active, isFalse);
      expect(state.startLine, isNull);
      expect(state.endLine, isNull);
      expect(state.hiddenLines(10), isEmpty);
    });

    test('narrowTo activates and reports the requested bounds', () {
      final NarrowState state = NarrowState();
      state.narrowTo(2, 5);
      expect(state.active, isTrue);
      expect(state.startLine, 2);
      expect(state.endLine, 5);
    });

    test('narrowTo normalizes a reversed range', () {
      final NarrowState state = NarrowState();
      state.narrowTo(7, 3);
      expect(state.startLine, 3);
      expect(state.endLine, 7);
    });

    test('widen clears narrowing back to inactive', () {
      final NarrowState state = NarrowState();
      state.narrowTo(1, 3);
      state.widen();
      expect(state.active, isFalse);
      expect(state.startLine, isNull);
      expect(state.endLine, isNull);
      expect(state.hiddenLines(10), isEmpty);
    });

    test('hiddenLines excludes exactly the narrowed range, middle case', () {
      final NarrowState state = NarrowState();
      state.narrowTo(3, 6);
      final Set<int> hidden = state.hiddenLines(10);
      expect(hidden, <int>{0, 1, 2, 7, 8, 9});
    });

    test(
        'hiddenLines includes first and last line when narrowed away from '
        'the edges', () {
      final NarrowState state = NarrowState();
      state.narrowTo(1, 8);
      final Set<int> hidden = state.hiddenLines(10);
      expect(hidden.contains(0), isTrue);
      expect(hidden.contains(9), isTrue);
      expect(hidden.contains(1), isFalse);
      expect(hidden.contains(8), isFalse);
    });

    test(
        'hiddenLines is empty when the narrowed range covers the whole '
        'buffer', () {
      final NarrowState state = NarrowState();
      state.narrowTo(0, 9);
      expect(state.hiddenLines(10), isEmpty);
    });

    test(
        'hiddenLines: single-line narrow at start hides everything after '
        'it', () {
      final NarrowState state = NarrowState();
      state.narrowTo(0, 0);
      final Set<int> hidden = state.hiddenLines(5);
      expect(hidden, <int>{1, 2, 3, 4});
    });

    test(
        'hiddenLines: single-line narrow at the last line hides everything '
        'before it', () {
      final NarrowState state = NarrowState();
      state.narrowTo(4, 4);
      final Set<int> hidden = state.hiddenLines(5);
      expect(hidden, <int>{0, 1, 2, 3});
    });

    test('hiddenLines: single-line narrow in the middle hides both sides', () {
      final NarrowState state = NarrowState();
      state.narrowTo(2, 2);
      final Set<int> hidden = state.hiddenLines(5);
      expect(hidden, <int>{0, 1, 3, 4});
    });

    test('hiddenLines with totalLines 0 is always empty even when active', () {
      final NarrowState state = NarrowState();
      state.narrowTo(0, 3);
      expect(state.hiddenLines(0), isEmpty);
    });
  });
}
