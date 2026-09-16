import 'kana.dart';

/// Pure, Flutter-free state machine for **incremental** romaji→hiragana input.
///
/// Unlike a boundary-triggered converter, this buffer converts *eagerly*: each
/// completed mora is emitted the moment it can no longer be extended, while an
/// unresolved prefix (e.g. `k`, `ky`, `sh`, `ch`, `ts`, `n`) is kept pending
/// and shown to the user as raw romaji. So typing `wa` shows わ immediately,
/// `watashi` becomes わたし as typed, `kyo` → きょ, gemination `kk` → っ (then
/// resolves to e.g. っか), `n`+vowel → な while `nn` → ん, and so on.
///
/// ## Editor contract
///
/// The editor always shows, at the caret, the already-finalised kana followed
/// by the current *pending raw* romaji. Each [feed] returns a [RomajiResult]
/// describing how to update the buffer:
///
///   * [RomajiResult.deleteBefore] — delete this many characters immediately
///     *before* the caret first. This is the length of the pending raw romaji
///     that was visible before this keystroke (it is about to be replaced by
///     newly-finalised kana plus the new pending raw).
///   * [RomajiResult.insert] — then insert this text at the caret. It is the
///     concatenation of any newly-finalised kana, the new pending raw romaji,
///     and (for a boundary keystroke) the boundary character itself.
///   * [RomajiResult.handled] — when `true` the editor must consume the key so
///     the underlying `TextField` does not *also* insert it (the buffer has
///     already inserted everything). When `false` the original character is
///     not romaji input; the editor performs [insert]/[deleteBefore] (to flush
///     any pending romaji) and then lets the original character fall through to
///     the `TextField` unchanged.
///
/// This single shape covers what used to be three separate result variants
/// (pending / commit / pass-through): the editor performs the same
/// delete-then-insert for every keystroke.
///
/// The IME-composing guard lives in the editor: while the OS IME has an active
/// composing region the editor does not feed characters here at all.
///
/// Carries *no mutable global state* and is safe to construct per-buffer or
/// per-session.
class RomajiInputBuffer {
  /// The unresolved romaji prefix currently shown to the user (raw, lower-case
  /// except for the pass-through of unmapped characters).
  String _pending = '';

  /// Number of pending (unconverted) raw romaji characters currently shown.
  int get pendingLength => _pending.length;

  /// True when there are unconverted characters waiting in the buffer.
  bool get hasPending => _pending.isNotEmpty;

  /// Feed a single typed character. See the class doc for the contract.
  ///
  /// Behaviour:
  ///   * **Lower/upper ASCII letter** — folded to lower-case, appended to the
  ///     pending buffer, then as many complete morae as possible are peeled off
  ///     the front and emitted. `handled = true`.
  ///   * **Boundary character** (space, tab, newline, ASCII punctuation that
  ///     cannot appear in romaji) — any pending romaji is finalised, then the
  ///     boundary character is appended verbatim. `handled = true`.
  ///   * **Anything else** (digit, non-ASCII, already-kana, control char) —
  ///     any pending romaji is finalised and returned in [RomajiResult.insert];
  ///     the original character is *not* consumed (`handled = false`) so the
  ///     editor lets it through to the `TextField`.
  RomajiResult feed(final String ch) {
    if (ch.isEmpty) {
      return const RomajiResult(insert: '', deleteBefore: 0, handled: false);
    }

    final code = ch.codeUnitAt(0);
    final isLetter = (code >= 0x61 && code <= 0x7A) || // a–z
        (code >= 0x41 && code <= 0x5A); // A–Z

    final prevPending = _pending.length;

    // 1. Romaji letter: append (lower-cased) and emit every completed mora,
    //    keeping only the lookahead-sensitive tail pending.
    if (isLetter) {
      _pending += ch.toLowerCase();
      final emitted = _emitStableFront();
      // The visible pending romaji is replaced wholesale: delete the old
      // pending chars, insert the finalised kana plus the new pending raw.
      return RomajiResult(
        insert: emitted + _pending,
        deleteBefore: prevPending,
        handled: true,
      );
    }

    // 2. Boundary character: finalise pending, append the boundary verbatim.
    if (_isBoundary(code)) {
      final flushed = _flushAll();
      return RomajiResult(
        insert: flushed + ch,
        deleteBefore: prevPending,
        handled: true,
      );
    }

    // 3. Pass-through (digit / non-ASCII / control): finalise pending; the
    //    original character is handled by the TextField, not consumed here.
    final flushed = _flushAll();
    return RomajiResult(
      insert: flushed,
      deleteBefore: prevPending,
      handled: false,
    );
  }

  /// Flush any pending romaji unconditionally and return the converted text.
  ///
  /// Returns an empty string if nothing was pending. The internal buffer is
  /// cleared regardless. Callers (e.g. toggling kana mode off, switching
  /// buffers without a boundary) use this to commit a trailing fragment; the
  /// returned text replaces the [pendingLength] raw characters that were
  /// visible. A trailing lone `n` becomes ん; other partial fragments (e.g.
  /// `k`, `ky`, `sh`) pass through as raw romaji.
  String flush() => _flushAll();

  /// Clear the pending buffer without converting (e.g. on Escape / cancel).
  void cancel() => _pending = '';

  /// Drop the last pending raw character (an in-progress romaji prefix), if any,
  /// and report whether one was removed.
  ///
  /// The pending buffer only ever holds an unresolved prefix — completed morae
  /// are emitted eagerly by [feed] — so truncating it by one character always
  /// leaves another valid prefix (`sh`→`s`, `ky`→`k`, `k`→``). The editor uses
  /// this for Backspace/Delete while composing so each press removes exactly one
  /// glyph instead of discarding the whole half-typed tail.
  bool backspace() {
    if (_pending.isEmpty) return false;
    _pending = _pending.substring(0, _pending.length - 1);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Emit every *completed* mora from the front of [_pending], stopping when the
  /// whole remaining buffer is lookahead-sensitive (kept as raw pending).
  /// Returns the finalised kana.
  ///
  /// The buffer is "lookahead-sensitive" — and therefore kept pending — when it
  /// is, in its entirety, either a strict romaji prefix ([Kana.isRomajiPrefix])
  /// such as `k`, `ky`, `sh`, `ts`, `tch`, or a run of `n` characters (the
  /// ambiguity between ん and an n-row kana, resolved only once a following
  /// character arrives). Otherwise the front holds at least one fully-determined
  /// mora, which is peeled and emitted by [_peelOneUnit]; the loop repeats on
  /// the remainder.
  ///
  /// The per-unit rules mirror [Kana.romajiToHiragana] exactly (gemination,
  /// the n-row three-character lookahead, youon, longest-match), so the eager
  /// per-mora output is identical to the batch converter's.
  String _emitStableFront() {
    final out = StringBuffer();
    while (_pending.isNotEmpty && !_isSensitive(_pending)) {
      if (!_peelOneUnit(out)) break; // safety: never spin
    }
    return out.toString();
  }

  /// Whether [s] (the whole pending buffer) must be kept pending because more
  /// input could still change its conversion: a strict romaji prefix, or a
  /// trailing-only run of `n`s.
  static bool _isSensitive(final String s) =>
      Kana.isRomajiPrefix(s) || _isAllN(s);

  /// Resolve and emit exactly one mora from the front of [_pending] into [out],
  /// shrinking [_pending]. Only called when the buffer is *not* fully sensitive,
  /// so a determinate unit exists at the front. Returns false only as an
  /// anti-spin guard (never for a non-empty buffer).
  ///
  /// Order mirrors [Kana.romajiToHiragana]: gemination → standalone-n →
  /// longest table unit → verbatim pass-through.
  bool _peelOneUnit(final StringBuffer out) {
    if (_pending.isEmpty) return false;
    final c0 = _pending[0];
    final c1 = _pending.length >= 2 ? _pending[1] : '';
    final c2 = _pending.length >= 3 ? _pending[2] : '';

    // 1. Gemination: doubled consonant (not 'n') → っ; keep the second copy.
    if (Kana.isGeminationConsonant(c0) && c1 == c0) {
      out.write('っ');
      _pending = _pending.substring(1);
      return true;
    }

    // 2. Standalone single 'n' → ん. Mirrors romajiToHiragana's conditions:
    //      (b) next is a consonant other than 'n'/'y'  → `nk` → ん + k
    //      (c) next is 'n' AND the char after is a vowel → `nni` → ん + に
    //    (Condition (a), a lone trailing 'n', is handled by the sensitive
    //    n-run guard, which keeps it pending instead.) A plain 'n'+vowel
    //    ('na'/'ni'…), 'ny*', and a non-vowel-followed 'nn' fall through to the
    //    table branch, which emits the n-row / youon / explicit `nn` kana.
    if (c0 == 'n' && c1.isNotEmpty) {
      final beforeConsonant = c1 != 'n' && c1 != 'y' && !Kana.isVowel(c1);
      final nBeforeNVowel = c1 == 'n' && Kana.isVowel(c2);
      if (beforeConsonant || nBeforeNVowel) {
        out.write('ん');
        _pending = _pending.substring(1);
        return true;
      }
    }

    // 3. Longest table unit (`nn` → ん, `kya` → きゃ, `ka` → か, …).
    final unit = Kana.longestRomajiUnitAt(_pending);
    if (unit != null) {
      out.write(unit.$2);
      _pending = _pending.substring(unit.$1.length);
      return true;
    }

    // 4. Pass-through: an unmapped ASCII letter (q, l, v, x, …) — emit verbatim.
    out.write(c0);
    _pending = _pending.substring(1);
    return true;
  }

  /// True when [s] is a non-empty string consisting solely of `n` characters.
  static bool _isAllN(final String s) {
    if (s.isEmpty) return false;
    for (var i = 0; i < s.length; i++) {
      if (s[i] != 'n') return false;
    }
    return true;
  }

  /// Finalise *all* pending romaji (boundary / pass-through / explicit flush),
  /// returning the converted text and clearing the buffer. Unlike
  /// [_peelCompletedMorae], this resolves the trailing fragment too: a lone
  /// trailing 'n' becomes ん, and any other leftover passes through verbatim
  /// (matching [Kana.romajiToHiragana] at end-of-input).
  String _flushAll() {
    if (_pending.isEmpty) return '';
    final raw = _pending;
    _pending = '';
    return Kana.romajiToHiragana(raw);
  }

  /// Returns true for ASCII characters that act as romaji boundaries.
  ///
  /// A boundary is any printable ASCII that cannot appear in Hepburn romaji:
  /// space, tab, newline, and ASCII punctuation.
  static bool _isBoundary(final int code) {
    // Whitespace.
    if (code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D) {
      return true;
    }
    // ASCII printable punctuation: 0x21–0x2F, 0x3A–0x40, 0x5B–0x60, 0x7B–0x7E
    // (everything in the ASCII printable range that is NOT a letter or digit).
    if ((code >= 0x21 && code <= 0x2F) ||
        (code >= 0x3A && code <= 0x40) ||
        (code >= 0x5B && code <= 0x60) ||
        (code >= 0x7B && code <= 0x7E)) {
      return true;
    }
    return false;
  }
}

/// The result of feeding one character into [RomajiInputBuffer].
///
/// Describes a single delete-then-insert edit at the caret plus whether the
/// editor should consume the triggering key. See [RomajiInputBuffer] for the
/// full contract.
class RomajiResult {
  const RomajiResult({
    required this.insert,
    required this.deleteBefore,
    required this.handled,
  });

  /// Text to insert at the caret (newly-finalised kana + new pending raw +
  /// any boundary character). May be empty.
  final String insert;

  /// How many characters to delete immediately before the caret *before*
  /// inserting [insert] — i.e. the length of the previously-visible pending
  /// raw romaji being replaced.
  final int deleteBefore;

  /// When `true`, the editor consumes the triggering key (do not let the
  /// `TextField` also insert it). When `false`, the original character was not
  /// romaji input and must fall through to the `TextField` after this edit.
  final bool handled;
}
