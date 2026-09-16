// Tests for SequenceMatcher — config-driven multi-stroke key-sequence dispatch.
//
// Table-driven where natural; individual tests where the scenario is singular.
// Covers all semantics documented in the class: arm→pending, complete→matched,
// immediate-match disambiguation, cancel-via-chord, cancel-via-non-matching,
// cancel exposes swallowed stroke, timeout via injected clock, reset, multi-
// prefix tries (C-x and C-c trees), single-stroke sequences → idle, and the
// resolveIntent registry helper.
library;

import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// C-<key> chord.
KeyChord ctrl(LogicalKeyboardKey key) =>
    KeyChord(keyId: key.keyId, control: true);

/// Bare (no modifier) chord.
KeyChord bare(LogicalKeyboardKey key) => KeyChord(keyId: key.keyId);

/// Build a two-stroke [KeyChordSequence] from two [KeyChord]s.
KeyChordSequence seq2(KeyChord a, KeyChord b) =>
    KeyChordSequence(<KeyChord>[a, b]);

/// Build a three-stroke [KeyChordSequence].
KeyChordSequence seq3(KeyChord a, KeyChord b, KeyChord c) =>
    KeyChordSequence(<KeyChord>[a, b, c]);

// Common chords used across multiple tests.
final _cx = ctrl(LogicalKeyboardKey.keyX); // C-x
final _cs = ctrl(LogicalKeyboardKey.keyS); // C-s
final _cf = ctrl(LogicalKeyboardKey.keyF); // C-f
final _cc = ctrl(LogicalKeyboardKey.keyC); // C-c
final _cn = ctrl(LogicalKeyboardKey.keyN); // C-n
final _cg = ctrl(LogicalKeyboardKey.keyG); // C-g (cancel)
final _esc = bare(LogicalKeyboardKey.escape); // Escape (cancel)
final _bB = bare(LogicalKeyboardKey.keyB); // bare b
final _bK = bare(LogicalKeyboardKey.keyK); // bare k
final _bA = bare(LogicalKeyboardKey.keyA); // bare a (no binding)

// --- sequences used in tests -------------------------------------------------

// C-x C-s → 'save'
final _cxcs = seq2(_cx, _cs);
// C-x C-f → 'openFile'
final _cxcf = seq2(_cx, _cf);
// C-x b   → 'switchBuffer'
final _cxb = seq2(_cx, _bB);
// C-x k   → 'killBuffer'
final _cxk = seq2(_cx, _bK);
// C-c C-n  → 'moveNextLine'
final _cccn = seq2(_cc, _cn);

/// Default bindings for most tests (C-x tree + one C-c entry).
Map<KeyChordSequence, String> _defaultBindings() => <KeyChordSequence, String>{
      _cxcs: 'save',
      _cxcf: 'openFile',
      _cxb: 'switchBuffer',
      _cxk: 'killBuffer',
      _cccn: 'moveNextLine',
    };

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // 1. Arm → pending label
  // =========================================================================
  group('arm → pending', () {
    test('feeding C-x returns pending with correct label', () {
      final m = SequenceMatcher(_defaultBindings());
      final r = m.feed(_cx);
      expect(r, isA<SequenceMatchPending>());
      final p = r as SequenceMatchPending;
      expect(p.pendingLabel, contains('–'));
      expect(p.pendingLabel, contains('Ctrl'));
      expect(m.isPending, isTrue);
      expect(m.pendingStrokes, <KeyChord>[_cx]);
    });

    test('feeding C-c returns pending for C-c C-n tree', () {
      final m = SequenceMatcher(_defaultBindings());
      final r = m.feed(_cc);
      expect(r, isA<SequenceMatchPending>());
      expect((r as SequenceMatchPending).pendingStrokes, <KeyChord>[_cc]);
    });

    test('pendingLabel contains all consumed strokes separated by space', () {
      // Build a 3-stroke prefix: C-x C-s C-f → just testing the label format.
      final threeStroke = seq3(_cx, _cs, _cf);
      final m = SequenceMatcher(<KeyChordSequence, String>{
        threeStroke: 'threeSave',
      });
      final r1 = m.feed(_cx);
      expect(r1, isA<SequenceMatchPending>());
      final r2 = m.feed(_cs);
      expect(r2, isA<SequenceMatchPending>());
      final pending = r2 as SequenceMatchPending;
      // Label should mention both strokes plus the trailing dash.
      expect(pending.pendingLabel, contains('–'));
      expect(pending.pendingStrokes.length, 2);
    });
  });

  // =========================================================================
  // 2. Complete → matched id
  // =========================================================================
  group('complete → matched', () {
    late SequenceMatcher m;
    setUp(() => m = SequenceMatcher(_defaultBindings()));

    final table = <(KeyChord, KeyChord, String)>[
      (_cx, _cs, 'save'),
      (_cx, _cf, 'openFile'),
      (_cx, _bB, 'switchBuffer'),
      (_cx, _bK, 'killBuffer'),
    ];

    for (final (first, second, id) in table) {
      test('$first $second → $id', () {
        final r1 = m.feed(first);
        expect(r1, isA<SequenceMatchPending>(), reason: 'first stroke arms');
        final r2 = m.feed(second);
        expect(r2, isA<SequenceMatchMatched>(),
            reason: 'second stroke matches');
        final matched = r2 as SequenceMatchMatched;
        expect(matched.intentId, id);
        expect(matched.sequence, KeyChordSequence(<KeyChord>[first, second]));
        expect(m.isPending, isFalse, reason: 'resets after match');
      });

      // Reset between table entries (setUp only creates once; tearDown cleans).
      tearDown(() => m.reset());
    }
  });

  // =========================================================================
  // 3. Immediate-match disambiguation
  // =========================================================================
  group('immediate-match disambiguation', () {
    test(
      'binding on C-x matches even when C-x C-s also exists',
      () {
        // "C-x" (single-stroke would be ShortcutActivator, but as a 2-entry
        // test we add a two-stroke sequence starting with C-x and also bind
        // C-x itself as a *two-stroke* sequence of length 1 — but
        // SequenceMatcher skips length-1 sequences.  The correct test:
        // add "C-x C-s" and "C-x C-s C-f" to prove that C-x C-s matches
        // immediately even though C-x C-s is a prefix of C-x C-s C-f.)
        final shorter = seq2(_cx, _cs); // C-x C-s → 'save'
        final longer = seq3(_cx, _cs, _cf); // C-x C-s C-f → 'deepSave'
        final m = SequenceMatcher(<KeyChordSequence, String>{
          shorter: 'save',
          longer: 'deepSave',
        });

        // Arm with C-x.
        final r1 = m.feed(_cx);
        expect(r1, isA<SequenceMatchPending>());

        // Feed C-s — completes 'C-x C-s' even though 'C-x C-s C-f' exists.
        final r2 = m.feed(_cs);
        expect(r2, isA<SequenceMatchMatched>());
        expect((r2 as SequenceMatchMatched).intentId, 'save');
        expect(m.isPending, isFalse);
      },
    );
  });

  // =========================================================================
  // 4. Cancel via C-g
  // =========================================================================
  group('cancel via C-g', () {
    test('C-g while pending cancels with no swallowed stroke', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx); // arm
      final r = m.feed(_cg);
      expect(r, isA<SequenceMatchCancelled>());
      expect((r as SequenceMatchCancelled).swallowedStroke, isNull);
      expect(m.isPending, isFalse);
    });

    test('C-g while idle returns idle (not cancelled)', () {
      final m = SequenceMatcher(_defaultBindings());
      // C-g is a cancel chord, but when not pending the stroke should be idle
      // (no sequence in the trie starts with C-g).
      final r = m.feed(_cg);
      expect(r, isA<SequenceMatchIdle>());
    });
  });

  // =========================================================================
  // 5. Cancel via Escape
  // =========================================================================
  group('cancel via Escape', () {
    test('Escape while pending cancels with no swallowed stroke', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx); // arm
      final r = m.feed(_esc);
      expect(r, isA<SequenceMatchCancelled>());
      expect((r as SequenceMatchCancelled).swallowedStroke, isNull);
      expect(m.isPending, isFalse);
    });
  });

  // =========================================================================
  // 6. Non-matching stroke while pending → cancelled + swallowed stroke
  // =========================================================================
  group('non-matching stroke cancels + exposes swallowed stroke', () {
    test('unrecognised second stroke returns cancelled with swallowed chord',
        () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx); // arm C-x
      // 'bare a' is not a known second stroke in the C-x tree.
      final r = m.feed(_bA);
      expect(r, isA<SequenceMatchCancelled>());
      final cancelled = r as SequenceMatchCancelled;
      expect(cancelled.swallowedStroke, _bA);
      expect(m.isPending, isFalse);
    });

    test('after cancellation, matcher is idle and accepts new sequences', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx);
      m.feed(_bA); // cancels
      // Now arm again cleanly.
      final r = m.feed(_cx);
      expect(r, isA<SequenceMatchPending>());
    });
  });

  // =========================================================================
  // 7. Timeout via injected clock
  // =========================================================================
  group('timeout via injected clock', () {
    test('tick() returns null when not pending', () {
      final m = SequenceMatcher(
        _defaultBindings(),
        timeout: const Duration(milliseconds: 500),
      );
      final r = m.tick(DateTime.now());
      expect(r, isNull);
    });

    test('tick() before timeout elapses returns null', () {
      final m = SequenceMatcher(
        _defaultBindings(),
        timeout: const Duration(milliseconds: 500),
      );
      final start = DateTime.now();
      m.feed(_cx); // arm
      // Tick with a time 100ms after arming — not yet expired.
      final r = m.tick(start.add(const Duration(milliseconds: 100)));
      expect(r, isNull);
      expect(m.isPending, isTrue);
    });

    test('tick() at or after timeout returns cancelled and resets', () {
      final m = SequenceMatcher(
        _defaultBindings(),
        timeout: const Duration(milliseconds: 500),
      );
      m.feed(_cx); // arm; internally records pendingStart = DateTime.now()

      // Simulate time passing beyond timeout by passing a future time.
      // We can't control the internal _pendingStart directly, so we pass a
      // time far enough in the future to exceed any possible elapsed time.
      final farFuture = DateTime.now().add(const Duration(seconds: 10));
      final r = m.tick(farFuture);
      expect(r, isA<SequenceMatchCancelled>());
      expect(m.isPending, isFalse);
    });

    test('no timeout set: tick() always returns null', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx); // arm
      final r = m.tick(
        DateTime.now().add(const Duration(hours: 1)),
      );
      expect(r, isNull); // no timeout configured
    });
  });

  // =========================================================================
  // 8. reset()
  // =========================================================================
  group('reset()', () {
    test('reset() while pending clears state', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx); // arm
      expect(m.isPending, isTrue);
      m.reset();
      expect(m.isPending, isFalse);
      expect(m.pendingStrokes, isEmpty);
    });

    test('reset() while idle is a no-op', () {
      final m = SequenceMatcher(_defaultBindings());
      expect(() => m.reset(), returnsNormally);
      expect(m.isPending, isFalse);
    });
  });

  // =========================================================================
  // 9. cancel() API
  // =========================================================================
  group('cancel() API', () {
    test('cancel() while pending returns SequenceMatchCancelled', () {
      final m = SequenceMatcher(_defaultBindings());
      m.feed(_cx);
      final r = m.cancel();
      expect(r, isA<SequenceMatchCancelled>());
      expect((r as SequenceMatchCancelled).swallowedStroke, isNull);
      expect(m.isPending, isFalse);
    });

    test('cancel() while idle returns null', () {
      final m = SequenceMatcher(_defaultBindings());
      final r = m.cancel();
      expect(r, isNull);
    });
  });

  // =========================================================================
  // 10. Multi-prefix tries (C-x and C-c trees)
  // =========================================================================
  group('multi-prefix tries', () {
    test('C-x and C-c trees coexist without confusion', () {
      final m = SequenceMatcher(_defaultBindings());

      // C-c C-n → 'moveNextLine'
      final r1 = m.feed(_cc);
      expect(r1, isA<SequenceMatchPending>());
      final r2 = m.feed(_cn);
      expect(r2, isA<SequenceMatchMatched>());
      expect((r2 as SequenceMatchMatched).intentId, 'moveNextLine');

      // C-x C-s → 'save' (same matcher, after reset from previous match)
      expect(m.isPending, isFalse);
      final r3 = m.feed(_cx);
      expect(r3, isA<SequenceMatchPending>());
      final r4 = m.feed(_cs);
      expect(r4, isA<SequenceMatchMatched>());
      expect((r4 as SequenceMatchMatched).intentId, 'save');
    });

    test('unrecognised first stroke from C-x or C-c tree is idle', () {
      final m = SequenceMatcher(_defaultBindings());
      // C-n alone is not a prefix of any multi-stroke sequence.
      final r = m.feed(_cn);
      expect(r, isA<SequenceMatchIdle>());
    });
  });

  // =========================================================================
  // 11. Single-stroke sequences are NOT matched by SequenceMatcher
  // =========================================================================
  group('single-stroke sequences → idle', () {
    test('a length-1 sequence in the binding map returns idle', () {
      // Even if passed to the constructor, length-1 sequences are ignored.
      final singleStroke = KeyChordSequence.single(_cs); // C-s → 'save'
      final m = SequenceMatcher(<KeyChordSequence, String>{
        singleStroke: 'save',
        _cxcs: 'save', // also has a two-stroke version
      });
      // Feeding C-s alone should return idle (not matched) since single-stroke
      // sequences belong in ShortcutActivator, not here.
      final r = m.feed(_cs);
      expect(r, isA<SequenceMatchIdle>());
    });

    test('feeding C-x arms even when single-stroke C-x binding also present',
        () {
      final singleCX = KeyChordSequence.single(_cx);
      final m = SequenceMatcher(<KeyChordSequence, String>{
        singleCX: 'prefixCtrlX', // ignored by trie
        _cxcs: 'save',
      });
      // C-x should arm the prefix (single-stroke entry is ignored).
      final r = m.feed(_cx);
      expect(r, isA<SequenceMatchPending>());
    });
  });

  // =========================================================================
  // 12. resolveIntent registry helper
  // =========================================================================
  group('resolveIntent registry integration', () {
    test('resolves a matched intentId to the correct Intent type', () {
      final registry = KeymapRegistry.defaults();
      // 'save' → SaveBufferIntent
      final intent = resolveIntent('save', registry);
      expect(intent, isNotNull);
      expect(intent, isA<SaveBufferIntent>());
    });

    test('resolves switchBuffer to SwitchBufferIntent', () {
      final registry = KeymapRegistry.defaults();
      final intent = resolveIntent('switchBuffer', registry);
      expect(intent, isA<SwitchBufferIntent>());
    });

    test('resolves killBuffer to KillBufferIntent', () {
      final registry = KeymapRegistry.defaults();
      final intent = resolveIntent('killBuffer', registry);
      expect(intent, isA<KillBufferIntent>());
    });

    test('resolves openFile to OpenFileIntent', () {
      final registry = KeymapRegistry.defaults();
      final intent = resolveIntent('openFile', registry);
      expect(intent, isA<OpenFileIntent>());
    });

    test('returns null for unknown id', () {
      final registry = KeymapRegistry.defaults();
      final intent = resolveIntent('nonExistentId', registry);
      expect(intent, isNull);
    });

    test('full round-trip: feed → match → resolve → Intent', () {
      final registry = KeymapRegistry.defaults();
      final m = SequenceMatcher(
        KeymapConfig.fromDefaults(registry).sequenceBindings(KeymapMode.emacs),
      );
      m.feed(_cx);
      final r = m.feed(_cs);
      expect(r, isA<SequenceMatchMatched>());
      final matched = r as SequenceMatchMatched;
      final intent = resolveIntent(matched.intentId, registry);
      expect(intent, isNotNull);
      expect(intent, isA<SaveBufferIntent>());
    });
  });

  // =========================================================================
  // 13. Custom cancel chords
  // =========================================================================
  group('custom cancelChords', () {
    test('default C-g and Escape cancel; bare A does not', () {
      final m = SequenceMatcher(_defaultBindings());
      // C-g cancels.
      m.feed(_cx);
      expect(m.feed(_cg), isA<SequenceMatchCancelled>());

      // Escape cancels.
      m.feed(_cx);
      expect(m.feed(_esc), isA<SequenceMatchCancelled>());

      // bare A does not cancel while pending — it returns cancelled with a
      // swallowed stroke (unrecognised in C-x tree), which is different.
      m.feed(_cx);
      final r = m.feed(_bA);
      expect(r, isA<SequenceMatchCancelled>());
      expect((r as SequenceMatchCancelled).swallowedStroke, _bA);
    });

    test('custom cancelChords override default', () {
      // Use only bare-A as cancel chord; C-g is no longer a cancel.
      final m = SequenceMatcher(
        _defaultBindings(),
        cancelChords: {_bA},
      );
      m.feed(_cx);
      // bare A cancels cleanly (no swallowed stroke).
      final r1 = m.feed(_bA);
      expect(r1, isA<SequenceMatchCancelled>());
      expect((r1 as SequenceMatchCancelled).swallowedStroke, isNull);

      // C-g is now just an unrecognised stroke (swallowed, not clean cancel).
      m.feed(_cx);
      final r2 = m.feed(_cg);
      expect(r2, isA<SequenceMatchCancelled>());
      expect((r2 as SequenceMatchCancelled).swallowedStroke, _cg);
    });
  });

  // =========================================================================
  // 14. KeymapConfig.fromDefaults integration
  // =========================================================================
  group('KeymapConfig.fromDefaults integration', () {
    test('matcher over emacs sequenceBindings arms and matches C-x b', () {
      final registry = KeymapRegistry.defaults();
      final config = KeymapConfig.fromDefaults(registry);
      final m = SequenceMatcher(config.sequenceBindings(KeymapMode.emacs));

      final r1 = m.feed(_cx);
      expect(r1, isA<SequenceMatchPending>());
      final r2 = m.feed(_bB);
      expect(r2, isA<SequenceMatchMatched>());
      expect((r2 as SequenceMatchMatched).intentId, 'switchBuffer');
    });

    test('matcher over cua sequenceBindings is empty (idle for all strokes)',
        () {
      final registry = KeymapRegistry.defaults();
      final config = KeymapConfig.fromDefaults(registry);
      final m = SequenceMatcher(config.sequenceBindings(KeymapMode.cua));
      // CUA has no multi-stroke sequences.
      expect(m.feed(_cx), isA<SequenceMatchIdle>());
      expect(m.feed(_cs), isA<SequenceMatchIdle>());
    });
  });
}
