import 'package:desktop_kit/desktop_kit_kana.dart';
import 'package:flutter_test/flutter_test.dart';

/// Headless tests for [RomajiInputBuffer] — the pure domain class that drives
/// *incremental* (eager, per-mora) romaji→hiragana conversion in kana input
/// mode. No Flutter binding needed.
///
/// The editor applies each [RomajiResult] as: delete [RomajiResult.deleteBefore]
/// characters before the caret, then insert [RomajiResult.insert]; if
/// [RomajiResult.handled] is false the original character also falls through.
/// [typeAll] replays that against a running visible string so we can assert the
/// *visible editor text* a sequence of keystrokes produces.
void main() {
  RomajiInputBuffer makeBuffer() => RomajiInputBuffer();

  /// Replay [s] keystroke-by-keystroke and return the visible editor text. If
  /// [flushAtEnd] is set, a trailing pending fragment is flushed (as the editor
  /// does when kana mode toggles off or the buffer switches).
  String typeAll(String s, {bool flushAtEnd = false}) {
    final buf = makeBuffer();
    var visible = '';
    for (final ch in s.split('')) {
      final r = buf.feed(ch);
      if (r.deleteBefore > 0) {
        visible = visible.substring(0, visible.length - r.deleteBefore);
      }
      visible += r.insert;
      if (!r.handled) visible += ch;
    }
    if (flushAtEnd && buf.hasPending) {
      final pend = buf.pendingLength;
      visible = visible.substring(0, visible.length - pend) + buf.flush();
    }
    return visible;
  }

  // ---------------------------------------------------------------------------
  // Initial state
  // ---------------------------------------------------------------------------

  group('initial state', () {
    test('no pending chars at construction', () {
      final buf = makeBuffer();
      expect(buf.pendingLength, 0);
      expect(buf.hasPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Eager per-mora conversion — the headline behaviour
  // ---------------------------------------------------------------------------

  group('eager per-mora conversion (visible text as typed)', () {
    final cases = <(String, String)>[
      // Single mora emitted the instant it completes.
      ('wa', 'わ'),
      ('ka', 'か'),
      ('kyo', 'きょ'),
      // Whole words convert progressively.
      ('watashi', 'わたし'),
      ('sakura', 'さくら'),
      ('sushi', 'すし'),
      ('kyou', 'きょう'),
      ('nya', 'にゃ'),
      // Gemination: the doubled consonant becomes っ immediately.
      ('kk', 'っk'),
      ('gakkou', 'がっこう'),
      ('tta', 'った'),
      ('tchi', 'っち'),
      // n-handling.
      ('na', 'な'), // n + vowel → na-row
      ('nna', 'んな'), // double-n then vowel → ん + な
      ('anna', 'あんな'),
      ('konnichiwa', 'こんにちわ'),
      // Voiced / other rows.
      ('ji', 'じ'),
      // ASCII pass-through.
      ('xx', 'xx'),
      ('ka1', 'か1'),
      // Boundary commits pending and passes the boundary char through.
      ('wa ', 'わ '),
      ('konnichiwa!', 'こんにちわ!'),
    ];
    for (final (input, expected) in cases) {
      test('"$input" → "$expected"', () {
        expect(typeAll(input), expected);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Trailing prefix stays raw until disambiguated / flushed
  // ---------------------------------------------------------------------------

  group('trailing lookahead-sensitive prefix stays raw', () {
    // These fragments are incomplete and could still extend, so they remain
    // visible as raw romaji (no premature kana).
    final raw = <(String, String)>[
      ('k', 'k'),
      ('ky', 'ky'),
      ('sh', 'sh'),
      ('ch', 'ch'),
      ('ts', 'ts'),
      ('n', 'n'), // lone n is ambiguous (ん vs n-row) until the next char
      ('nn', 'nn'), // double-n still pending until we know if a vowel follows
      ('nihon', 'にほn'), // trailing n pending
    ];
    for (final (input, expected) in raw) {
      test('"$input" stays "$expected" (pending)', () {
        expect(typeAll(input), expected);
        // Confirm something is actually still pending for the partial cases.
        final buf = makeBuffer();
        for (final ch in input.split('')) {
          buf.feed(ch);
        }
        expect(buf.hasPending, isTrue);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // flush()/boundary finalisation — the trailing fragment resolves
  // ---------------------------------------------------------------------------

  group('flush resolves the trailing fragment', () {
    final cases = <(String, String)>[
      ('n', 'ん'), // lone trailing n → ん
      ('nn', 'ん'), // double-n → ん
      ('nihon', 'にほん'),
      ('gakkou', 'がっこう'),
      ('k', 'k'), // unconvertible partial passes through verbatim
      ('ky', 'ky'),
    ];
    for (final (input, expected) in cases) {
      test('type+flush "$input" → "$expected"', () {
        expect(typeAll(input, flushAtEnd: true), expected);
      });
    }

    test('boundary after lone n commits ん + the boundary', () {
      // n then space → ん then space (boundary finalises the pending n).
      expect(typeAll('n '), 'ん ');
    });

    test('flush with no pending returns empty string', () {
      expect(makeBuffer().flush(), '');
    });

    test('a completed mora is emitted eagerly, leaving nothing to flush', () {
      // "ko" completes こ on the second keystroke, so there is no pending tail.
      final buf = makeBuffer();
      buf.feed('k');
      buf.feed('o');
      expect(buf.hasPending, isFalse);
      expect(buf.flush(), '');
    });

    test('flush resolves a genuinely-pending trailing fragment', () {
      // "kon" → こ emitted + pending "n"; flush resolves the n → ん.
      final buf = makeBuffer();
      buf.feed('k');
      buf.feed('o');
      buf.feed('n');
      expect(buf.hasPending, isTrue);
      expect(buf.flush(), 'ん');
      expect(buf.hasPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // RomajiResult shape for individual keystrokes
  // ---------------------------------------------------------------------------

  group('RomajiResult shape', () {
    test('a completing keystroke replaces the pending raw with kana', () {
      final buf = makeBuffer();
      final r1 = buf.feed('k'); // pending 'k'
      expect(r1.handled, isTrue);
      expect(r1.deleteBefore, 0);
      expect(r1.insert, 'k');

      final r2 = buf.feed('a'); // completes か, replacing the visible 'k'
      expect(r2.handled, isTrue);
      expect(r2.deleteBefore, 1, reason: 'the raw "k" is replaced');
      expect(r2.insert, 'か');
    });

    test('boundary keystroke is consumed and inserts kana + boundary', () {
      final buf = makeBuffer();
      buf.feed('k');
      buf.feed('a');
      final r = buf.feed('!');
      expect(r.handled, isTrue);
      expect(r.insert, '!'); // pending already emitted; just the boundary
      expect(r.deleteBefore, 0);
    });

    test('boundary after pending replaces pending with kana + boundary', () {
      final buf = makeBuffer();
      buf.feed('n'); // pending 'n' (kept raw)
      final r = buf.feed(' '); // boundary → ん + space, replacing the raw 'n'
      expect(r.handled, isTrue);
      expect(r.deleteBefore, 1);
      expect(r.insert, 'ん ');
    });

    test('digit is not consumed; flushes pending kana first', () {
      final buf = makeBuffer();
      buf.feed('k');
      buf.feed('a'); // emits か (pending now empty)
      final r = buf.feed('1');
      expect(r.handled, isFalse, reason: 'digit falls through to the field');
      expect(r.insert, ''); // nothing pending to flush
      expect(r.deleteBefore, 0);
    });

    test(
      'digit after an unconvertible partial flushes it raw, not consumed',
      () {
        final buf = makeBuffer();
        buf.feed('k'); // pending 'k'
        final r = buf.feed('1');
        expect(r.handled, isFalse);
        expect(r.deleteBefore, 1, reason: 'the raw "k" is replaced');
        expect(r.insert, 'k', reason: 'k alone has no kana, passes through');
      },
    );

    test('non-ASCII passes through, flushing pending kana', () {
      final buf = makeBuffer();
      buf.feed('s');
      buf.feed('h');
      buf.feed('i'); // し emitted
      final r = buf.feed('あ');
      expect(r.handled, isFalse);
      expect(r.insert, '');
    });
  });

  // ---------------------------------------------------------------------------
  // Upper-case folding
  // ---------------------------------------------------------------------------

  group('upper-case input folds to lower', () {
    test('"K","A" → か', () {
      expect(typeAll('KA'), 'か');
    });
  });

  // ---------------------------------------------------------------------------
  // cancel()
  // ---------------------------------------------------------------------------

  group('cancel()', () {
    test('cancel clears pending without converting', () {
      final buf = makeBuffer();
      buf.feed('k');
      buf.feed('a'); // emits か
      buf.feed('n'); // pending 'n'
      expect(buf.hasPending, isTrue);
      buf.cancel();
      expect(buf.pendingLength, 0);
      expect(buf.hasPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Real-word integration via flush()
  // ---------------------------------------------------------------------------

  group('real-word integration (type then flush)', () {
    final cases = <(String, String)>[
      ('sakura', 'さくら'),
      ('nihon', 'にほん'),
      ('sushi', 'すし'),
      ('anime', 'あにめ'),
      ('gakkou', 'がっこう'),
      ('kyou', 'きょう'),
      ('konnichiwa', 'こんにちわ'),
    ];
    for (final (input, expected) in cases) {
      test('"$input" → "$expected"', () {
        expect(typeAll(input, flushAtEnd: true), expected);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Invariant: eager incremental output == batch converter
  // ---------------------------------------------------------------------------
  //
  // The incremental path must never diverge from the single source of truth
  // ([Kana.romajiToHiragana]). For any word, typing it keystroke-by-keystroke
  // and flushing the trailing fragment must equal converting the whole string
  // in one shot. This pins down all the awkward lookahead cases (gemination,
  // the n-row three-character disambiguation, youon, `tch`).
  group('incremental == batch (adversarial words)', () {
    final words = [
      'tch',
      'tchi',
      'matcha',
      'kanyu',
      'shinbun',
      'gunma',
      'tennis',
      'happyou',
      'kippu',
      'zasshi',
      'jugyou',
      'ryokou',
      'fukuzatsu',
      'tsukue',
      'chotto',
      'gakkou',
      'konnichiwa',
      'arigatou',
      'nn',
      'nnn',
      'n',
      'nk',
      'nnk',
      'nya',
      'sayonara',
      'ohayou',
      'beddo',
      'webbu',
      'sakura',
      'watashi',
      'kyou',
      'nihon',
    ];
    for (final w in words) {
      test('typing "$w" then flush == Kana.romajiToHiragana("$w")', () {
        expect(
          typeAll(w, flushAtEnd: true),
          Kana.romajiToHiragana(w),
          reason: 'the eager path must match the batch converter',
        );
      });
    }
  });
}
