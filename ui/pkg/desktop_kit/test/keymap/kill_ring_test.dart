// Tests for KillRing: append-merge + yank/yank-pop semantics.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KillRing', () {
    test('starts empty', () {
      final ring = KillRing();
      expect(ring.isEmpty, isTrue);
      expect(ring.current, isNull);
      expect(ring.length, 0);
      expect(ring.lastWasKill, isFalse);
      expect(ring.canYankPop, isFalse);
    });

    test('kill pushes a fresh entry and resets yank pointer', () {
      final ring = KillRing();
      ring.kill('foo');
      ring.kill('bar');
      expect(ring.entries, ['bar', 'foo']);
      expect(ring.yankPointer, 0);
      expect(ring.current, 'bar');
    });

    test('kill ignores empty strings', () {
      final ring = KillRing();
      ring.kill('');
      expect(ring.isEmpty, isTrue);
      // lastWasKill is set even for empty kills
      expect(ring.lastWasKill, isTrue);
    });

    test('killAppend merges when previous was a kill', () {
      final ring = KillRing();
      ring.kill('hello ');
      ring.killAppend('world');
      expect(ring.entries, ['hello world']);
    });

    test('killAppend prepend merges in reverse', () {
      final ring = KillRing();
      ring.kill('world');
      ring.killAppend('hello ', prepend: true);
      expect(ring.entries, ['hello world']);
    });

    test('killAppend starts a new entry after breakKillSequence', () {
      final ring = KillRing();
      ring.kill('first');
      ring.breakKillSequence();
      ring.killAppend('second');
      expect(ring.entries, ['second', 'first']);
    });

    test('copy seeds the ring (alias for kill)', () {
      final ring = KillRing();
      ring.copy('copied');
      expect(ring.current, 'copied');
      expect(ring.lastWasKill, isTrue);
    });

    test('yank returns current entry and sets justYanked', () {
      final ring = KillRing();
      ring.kill('text');
      final t = ring.yank();
      expect(t, 'text');
      expect(ring.canYankPop, isTrue);
    });

    test('yank on empty ring returns empty string', () {
      final ring = KillRing();
      expect(ring.yank(), '');
      expect(ring.canYankPop, isFalse);
    });

    test('yankPop rotates through entries', () {
      final ring = KillRing();
      ring.kill('a');
      ring.kill('b');
      ring.kill('c');
      // ring: [c, b, a]
      ring.yank(); // c
      final p1 = ring.yankPop(); // b
      expect(p1, 'b');
      final p2 = ring.yankPop(); // a
      expect(p2, 'a');
      final p3 = ring.yankPop(); // wraps to c
      expect(p3, 'c');
    });

    test('yankPop returns null when not after a yank', () {
      final ring = KillRing();
      ring.kill('a');
      ring.kill('b');
      // no yank called yet
      expect(ring.yankPop(), isNull);
    });

    test('bounded to maxEntries', () {
      final ring = KillRing(maxEntries: 3);
      ring.kill('a');
      ring.kill('b');
      ring.kill('c');
      ring.kill('d');
      expect(ring.length, 3);
      expect(ring.entries, ['d', 'c', 'b']);
    });

    test('clear resets all state', () {
      final ring = KillRing();
      ring.kill('x');
      ring.yank();
      ring.clear();
      expect(ring.isEmpty, isTrue);
      expect(ring.canYankPop, isFalse);
      expect(ring.lastWasKill, isFalse);
    });

    test('a yank breaks the kill sequence (next killAppend pushes fresh)', () {
      final ring = KillRing();
      ring.killAppend('kept');
      ring.yank(); // yank clears lastWasKill
      ring.killAppend('new');
      expect(ring.length, 2);
      expect(ring.entries, ['new', 'kept']);
    });

    group('setYankPointer', () {
      test('points yank at the chosen entry without a rotation', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.kill('c'); // ring: [c, b, a], pointer 0 -> c
        ring.setYankPointer(2);
        expect(ring.yankPointer, 2);
        expect(ring.current, 'a');
        expect(ring.yank(), 'a');
      });

      test('is a no-op for a negative index', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.setYankPointer(-1);
        expect(ring.yankPointer, 0);
      });

      test('is a no-op for an index at or past the ring length', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b'); // length 2, valid indices 0..1
        ring.setYankPointer(2);
        expect(ring.yankPointer, 0);
      });

      test('does not affect lastWasKill or canYankPop', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        expect(ring.lastWasKill, isTrue);
        ring.setYankPointer(1);
        expect(ring.lastWasKill, isTrue);
        expect(ring.canYankPop, isFalse);
      });
    });

    group('removeAt', () {
      test('removes the entry and shifts nothing else in the list', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.kill('c'); // [c, b, a]
        ring.removeAt(1); // remove 'b'
        expect(ring.entries, ['c', 'a']);
      });

      test('is a no-op for an out-of-range index', () {
        final ring = KillRing();
        ring.kill('a');
        ring.removeAt(5);
        ring.removeAt(-1);
        expect(ring.entries, ['a']);
      });

      test(
          'removing before the pointer shifts the pointer back by one, '
          'keeping it aimed at the same logical entry', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.kill('c'); // [c, b, a]
        ring.setYankPointer(2); // pointing at 'a'
        ring.removeAt(0); // remove 'c', which is before the pointer
        expect(ring.entries, ['b', 'a']);
        expect(ring.yankPointer, 1);
        expect(ring.current, 'a'); // still 'a' despite the index shift
      });

      test('removing the pointed-at entry clamps into range', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.kill('c'); // [c, b, a], pointer 2 -> 'a'
        ring.setYankPointer(2);
        ring.removeAt(2); // remove the entry the pointer is on
        expect(ring.entries, ['c', 'b']);
        expect(ring.yankPointer, 1); // clamped to the new last index
      });

      test(
          'removing the last entry empties the ring and resets the '
          'pointer', () {
        final ring = KillRing();
        ring.kill('only');
        ring.removeAt(0);
        expect(ring.isEmpty, isTrue);
        expect(ring.yankPointer, 0);
        expect(ring.current, isNull);
      });

      test(
          'removing multiple indices highest-to-lowest keeps every '
          'target valid — the documented required call order', () {
        final ring = KillRing();
        ring.kill('a');
        ring.kill('b');
        ring.kill('c');
        ring.kill('d'); // [d, c, b, a]
        // Delete 'c' (index 1) and 'a' (index 3) in one pass, descending.
        ring.removeAt(3);
        ring.removeAt(1);
        expect(ring.entries, ['d', 'b']);
      });
    });
  });
}
