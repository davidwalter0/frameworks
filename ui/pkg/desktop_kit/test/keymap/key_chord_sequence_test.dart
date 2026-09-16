// Tests for KeyChordSequence: construction, token round-trip (1/2/3 strokes),
// equality, prefix helpers, append/dropLast, malformed tokens, and the
// shadow-conflict detection helpers that live beside the model.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A control chord for [k] (C-<k>).
KeyChord _c(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId, control: true);

/// A bare (no-modifier) chord for [k].
KeyChord _bare(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId);

void main() {
  // Reused strokes.
  final cx = _c(LogicalKeyboardKey.keyX); // C-x
  final cs = _c(LogicalKeyboardKey.keyS); // C-s
  final cf = _c(LogicalKeyboardKey.keyF); // C-f
  final bBare = _bare(LogicalKeyboardKey.keyB); // b (plain letter)

  group('construction invariants', () {
    test('length-1 sequence is the common case', () {
      final s = KeyChordSequence.single(cx);
      expect(s.length, 1);
      expect(s.isSingle, isTrue);
      expect(s.first, cx);
      expect(s.last, cx);
      expect(s.asSingle, cx);
    });

    test('multi-stroke sequence exposes first/last/asSingle', () {
      final s = KeyChordSequence(<KeyChord>[cx, cs]);
      expect(s.length, 2);
      expect(s.isSingle, isFalse);
      expect(s.first, cx);
      expect(s.last, cs);
      expect(s.asSingle, isNull);
    });

    test('empty stroke list throws ArgumentError', () {
      expect(() => KeyChordSequence(<KeyChord>[]), throwsArgumentError);
    });

    test('strokes list is unmodifiable', () {
      final s = KeyChordSequence(<KeyChord>[cx, cs]);
      expect(() => s.strokes.add(cf), throwsUnsupportedError);
    });
  });

  group('token round-trip (table-driven)', () {
    // Each case: a sequence and its expected canonical token.
    final cases = <({String name, KeyChordSequence seq, String token})>[
      (
        name: '1-stroke C-x',
        seq: KeyChordSequence.single(cx),
        token: cx.token,
      ),
      (
        name: '1-stroke equals bare chord token (backward-compat)',
        seq: KeyChordSequence.single(cs),
        token: cs.token, // no spaces — identical to the pre-sequence token
      ),
      (
        name: '2-stroke C-x C-s',
        seq: KeyChordSequence(<KeyChord>[cx, cs]),
        token: '${cx.token} ${cs.token}',
      ),
      (
        name: '2-stroke C-x b (prefix + plain letter)',
        seq: KeyChordSequence(<KeyChord>[cx, bBare]),
        token: '${cx.token} ${bBare.token}',
      ),
      (
        name: '3-stroke C-x C-f C-s',
        seq: KeyChordSequence(<KeyChord>[cx, cf, cs]),
        token: '${cx.token} ${cf.token} ${cs.token}',
      ),
    ];

    for (final c in cases) {
      test('${c.name}: token matches and parse round-trips', () {
        expect(c.seq.token, c.token);
        final parsed = KeyChordSequence.parse(c.token);
        expect(parsed, c.seq);
        expect(parsed.token, c.token);
      });
    }

    test('single-stroke token contains no space (byte-stable with KeyChord)',
        () {
      final s = KeyChordSequence.single(cx);
      expect(s.token.contains(' '), isFalse);
      expect(s.token, cx.token);
    });

    test('parse tolerates extra internal whitespace', () {
      final parsed = KeyChordSequence.parse('${cx.token}   ${cs.token}');
      expect(parsed, KeyChordSequence(<KeyChord>[cx, cs]));
    });
  });

  group('parse rejects malformed tokens', () {
    test('empty / whitespace-only', () {
      expect(() => KeyChordSequence.parse(''), throwsFormatException);
      expect(() => KeyChordSequence.parse('   '), throwsFormatException);
    });

    test('a malformed stroke fails the whole sequence', () {
      // First stroke valid, second missing its keyId separator/int.
      expect(
        () => KeyChordSequence.parse('${cx.token} CS'),
        throwsFormatException,
      );
      expect(
        () => KeyChordSequence.parse('not-an-int'),
        throwsFormatException,
      );
    });
  });

  group('equality + hashCode', () {
    test('equal by value over ordered strokes', () {
      final a = KeyChordSequence(<KeyChord>[cx, cs]);
      final b = KeyChordSequence(<KeyChord>[cx, cs]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('order matters', () {
      final a = KeyChordSequence(<KeyChord>[cx, cs]);
      final b = KeyChordSequence(<KeyChord>[cs, cx]);
      expect(a, isNot(b));
    });

    test('length matters', () {
      final a = KeyChordSequence(<KeyChord>[cx]);
      final b = KeyChordSequence(<KeyChord>[cx, cs]);
      expect(a, isNot(b));
    });

    test('usable as a Map key', () {
      final map = <KeyChordSequence, String>{
        KeyChordSequence(<KeyChord>[cx, cs]): 'save',
      };
      expect(map[KeyChordSequence(<KeyChord>[cx, cs])], 'save');
      expect(map[KeyChordSequence(<KeyChord>[cx, cf])], isNull);
    });
  });

  group('label', () {
    test('joins per-stroke labels with spaces', () {
      final s = KeyChordSequence(<KeyChord>[cx, cs]);
      expect(s.label, 'Ctrl+X Ctrl+S');
    });

    test('single stroke label equals the chord label', () {
      expect(KeyChordSequence.single(cx).label, cx.label);
    });
  });

  group('prefix helpers (table-driven)', () {
    final cxcs = KeyChordSequence(<KeyChord>[cx, cs]); // C-x C-s
    final cx1 = KeyChordSequence.single(cx); // C-x
    final cxcf = KeyChordSequence(<KeyChord>[cx, cf]); // C-x C-f
    final cs1 = KeyChordSequence.single(cs); // C-s

    // (a, b, isPrefixOf, isProperPrefixOf)
    final cases = <({
      String name,
      KeyChordSequence a,
      KeyChordSequence b,
      bool prefix,
      bool proper,
    })>[
      (
        name: 'C-x prefixes C-x C-s',
        a: cx1,
        b: cxcs,
        prefix: true,
        proper: true
      ),
      (
        name: 'C-x C-s does not prefix C-x',
        a: cxcs,
        b: cx1,
        prefix: false,
        proper: false,
      ),
      (
        name: 'sequence is a (non-proper) prefix of itself',
        a: cxcs,
        b: cxcs,
        prefix: true,
        proper: false,
      ),
      (
        name: 'diverging second stroke is not a prefix',
        a: cxcf,
        b: cxcs,
        prefix: false,
        proper: false,
      ),
      (
        name: 'unrelated single is not a prefix',
        a: cs1,
        b: cxcs,
        prefix: false,
        proper: false,
      ),
    ];

    for (final c in cases) {
      test(c.name, () {
        expect(c.a.isPrefixOf(c.b), c.prefix, reason: 'isPrefixOf');
        expect(c.a.isProperPrefixOf(c.b), c.proper, reason: 'isProperPrefixOf');
        // startsWith is the dual of isPrefixOf.
        expect(c.b.startsWith(c.a), c.prefix, reason: 'startsWith dual');
      });
    }
  });

  group('append / dropLast', () {
    test('append adds a trailing stroke', () {
      final s = KeyChordSequence.single(cx).append(cs);
      expect(s, KeyChordSequence(<KeyChord>[cx, cs]));
    });

    test('dropLast removes the trailing stroke', () {
      final s = KeyChordSequence(<KeyChord>[cx, cs]).dropLast();
      expect(s, KeyChordSequence.single(cx));
    });

    test('dropLast on a length-1 sequence returns null (cannot empty)', () {
      expect(KeyChordSequence.single(cx).dropLast(), isNull);
    });
  });

  group('shadow-conflict detection', () {
    final cxcs = KeyChordSequence(<KeyChord>[cx, cs]);
    final cxcf = KeyChordSequence(<KeyChord>[cx, cf]);
    final cx1 = KeyChordSequence.single(cx);
    final cs1 = KeyChordSequence.single(cs);

    test('no conflict among single-stroke-only sequences', () {
      final conflicts = findShadowConflicts(<KeyChordSequence>[cx1, cs1]);
      expect(conflicts, isEmpty);
      expect(shadowedSequences(<KeyChordSequence>[cx1, cs1]), isEmpty);
    });

    test('a prefix binding shadows its longer sequence', () {
      // C-x is bound (prefix) while C-x C-s exists.
      final conflicts = findShadowConflicts(<KeyChordSequence>[cx1, cxcs]);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.prefix, cx1);
      expect(conflicts.single.shadowed, cxcs);
      // Both rows should be flagged.
      expect(shadowedSequences(<KeyChordSequence>[cx1, cxcs]), {cx1, cxcs});
    });

    test('prefix shadows every sequence it prefixes', () {
      final conflicts =
          findShadowConflicts(<KeyChordSequence>[cx1, cxcs, cxcf]);
      expect(conflicts, hasLength(2));
      expect(
        conflicts.map((c) => c.shadowed).toSet(),
        {cxcs, cxcf},
      );
      expect(conflicts.every((c) => c.prefix == cx1), isTrue);
    });

    test('two full sequences that only share a stroke do not conflict', () {
      // C-x C-s and C-x C-f: neither is a prefix of the other.
      final conflicts = findShadowConflicts(<KeyChordSequence>[cxcs, cxcf]);
      expect(conflicts, isEmpty);
    });

    test('conflicts are returned in a stable order', () {
      final unsorted = findShadowConflicts(<KeyChordSequence>[cxcf, cx1, cxcs]);
      final sorted = findShadowConflicts(<KeyChordSequence>[cx1, cxcs, cxcf]);
      expect(unsorted, sorted);
    });
  });
}
