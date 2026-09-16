import 'dart:async';

import 'package:flutter/foundation.dart';

import '../kana/kana.dart';
import 'anthy_egg.dart';

/// Which IME phase the active (preedit) region is in.
///
/// * [idle] — nothing is being composed; the editor has no active region.
/// * [composing] — romaji→hiragana is accumulating as a raw preedit; Anthy
///   has not been consulted yet.
/// * [converting] — the preedit has been converted to kanji and the user is
///   cycling candidates for the active segment.
enum ImePhase { idle, composing, converting }

/// Immutable view-state of the kana→kanji IME, sufficient for a widget to
/// paint the active region and for tests to assert on the conversion flow.
///
/// This is a pure value type: the controller produces a fresh [ImeState] on
/// every transition (no mutation in place), so listeners can diff old vs. new.
@immutable
class ImeState {
  const ImeState({
    required this.phase,
    required this.preedit,
    required this.displayText,
    required this.candidates,
    required this.candidateIndex,
    required this.activeSegment,
  });

  /// The idle/empty state — no active region.
  static const ImeState idle = ImeState(
    phase: ImePhase.idle,
    preedit: '',
    displayText: '',
    candidates: <String>[],
    candidateIndex: 0,
    activeSegment: 0,
  );

  /// Current IME phase.
  final ImePhase phase;

  /// The raw hiragana the user typed (the composing buffer). Preserved through
  /// the [ImePhase.converting] phase so Esc / Backspace can revert to it.
  final String preedit;

  /// What the editor should render in the active region:
  ///   * [ImePhase.composing] → the raw [preedit] hiragana.
  ///   * [ImePhase.converting] → the conversion text with the active segment
  ///     replaced by `candidates[candidateIndex]` (a join of every segment's
  ///     best, the active one substituted).
  ///   * [ImePhase.idle] → empty.
  final String displayText;

  /// Candidate strings for the active segment (empty unless converting).
  final List<String> candidates;

  /// Index into [candidates] of the currently-selected candidate.
  final int candidateIndex;

  /// The segment the user is cycling. Navigated with [ImeController.moveSegmentNext]
  /// / [ImeController.moveSegmentPrevious] (←/→ while converting).
  final int activeSegment;

  /// Whether there is an active region the editor must render specially.
  bool get isActive => phase != ImePhase.idle;

  ImeState copyWith({
    ImePhase? phase,
    String? preedit,
    String? displayText,
    List<String>? candidates,
    int? candidateIndex,
    int? activeSegment,
  }) {
    return ImeState(
      phase: phase ?? this.phase,
      preedit: preedit ?? this.preedit,
      displayText: displayText ?? this.displayText,
      candidates: candidates ?? this.candidates,
      candidateIndex: candidateIndex ?? this.candidateIndex,
      activeSegment: activeSegment ?? this.activeSegment,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImeState &&
      other.phase == phase &&
      other.preedit == preedit &&
      other.displayText == displayText &&
      listEquals(other.candidates, candidates) &&
      other.candidateIndex == candidateIndex &&
      other.activeSegment == activeSegment;

  @override
  int get hashCode => Object.hash(
        phase,
        preedit,
        displayText,
        Object.hashAll(candidates),
        candidateIndex,
        activeSegment,
      );

  @override
  String toString() => 'ImeState(${phase.name}, preedit="$preedit", '
      'display="$displayText", cands=$candidates@$candidateIndex, '
      'seg=$activeSegment)';
}

/// Headless conversion controller for the kana→kanji IME.
///
/// It owns the IME *logic* — no widgets — and drives an injected [AnthyEgg].
/// The user's interaction model (implemented exactly here):
///
///   * romaji→hiragana accumulates as the **preedit** ([feedKana]); the whole
///     run is one conversion group that stays active until Enter.
///   * **Space** ([space]) — first press converts the preedit to kanji (best);
///     each further press cycles **forward** through the active segment's
///     candidates.
///   * **Shift+Space** ([shiftSpace]) — cycles **backward** (wraps).
///   * **Enter** ([commit]) — finalizes; Anthy learns; returns the committed
///     string and resets to idle.
///   * **Esc** ([cancel]) — reverts to the raw hiragana and resets to idle,
///     returning that hiragana.
///   * **Backspace** ([backspace]) — while converting, reverts to composing
///     (the hiragana); while composing, deletes the last preedit char.
///   * **←/→** ([moveSegmentPrevious]/[moveSegmentNext]) — move the active
///     segment cursor while converting, loading that segment's candidates.
///   * **Shift+←/→** ([shrinkSegment]/[growSegment]) — resize the active
///     segment (re-segments the whole conversion via [AnthyEgg.resizeSegment])
///     and reloads the (possibly renumbered) active segment's candidates.
///
/// State is exposed two ways for convenience: a synchronous [state] getter and
/// a [ValueNotifier] ([notifier]) widgets/tests can listen to. They always
/// agree (the notifier's value *is* the current state).
class ImeController {
  ImeController(this._egg);

  final AnthyEgg _egg;

  /// Whether [AnthyEgg.start] has been awaited (lazy, on first driver use).
  bool _started = false;

  /// The most recent conversion result, kept so [displayText] can rebuild from
  /// every segment's best while a single active segment is being cycled. Null
  /// unless [ImePhase.converting].
  AnthyConversion? _conversion;

  final ValueNotifier<ImeState> _notifier = ValueNotifier<ImeState>(
    ImeState.idle,
  );

  /// Listenable view-state (for widgets in Phase-2b and for tests).
  ValueNotifier<ImeState> get notifier => _notifier;

  /// The current view-state (synchronous read).
  ImeState get state => _notifier.value;

  void _set(ImeState next) => _notifier.value = next;

  /// Ensure the egg is started exactly once before the first driver command.
  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    await _egg.start();
  }

  /// Append [hiragana] to the preedit. Composing-only: this is the romaji→kana
  /// accumulation, so it is **ignored while converting** — a conversion is a
  /// single committed-or-cancelled group and typing into the middle of one is
  /// meaningless.
  ///
  /// Callers must therefore NOT hand typed input straight here while
  /// converting: that silently destroys the character. Resolve the conversion
  /// first with [acceptForTyping] (the standard IME reading of "the user typed
  /// on, so they accepted it") — which is what [PreeditSession] does. Empty
  /// input is a no-op.
  void feedKana(String hiragana) {
    if (hiragana.isEmpty) return;
    if (state.phase == ImePhase.converting) return;
    final preedit = state.preedit + hiragana;
    _set(
      ImeState(
        phase: ImePhase.composing,
        preedit: preedit,
        displayText: preedit,
        candidates: const <String>[],
        candidateIndex: 0,
        activeSegment: 0,
      ),
    );
  }

  /// Space: convert (first press) or cycle the active segment forward (further
  /// presses).
  ///
  ///   * composing + non-empty preedit → [AnthyEgg.convert], enter
  ///     [ImePhase.converting] on segment 0, load that segment's candidates,
  ///     and select the candidate matching the segment's `best`.
  ///   * converting → advance `candidateIndex = (i + 1) % n`, push the choice
  ///     to Anthy via [AnthyEgg.selectCandidate], and recompose [displayText].
  ///
  /// Idle, or composing with an empty preedit, is a no-op.
  Future<void> space() async {
    final s = state;
    switch (s.phase) {
      case ImePhase.idle:
        return;
      case ImePhase.composing:
        if (s.preedit.isEmpty) return;
        await _convert(s.preedit);
      case ImePhase.converting:
        await _cycle(forward: true);
    }
  }

  /// Select an absolute candidate [index] for the active segment (used by a
  /// mouse click in the candidate panel). Only acts while converting; clamps
  /// [index] into [0, candidates.length); a no-op when it equals the current
  /// index. Mirrors the bookkeeping of space()/shiftSpace().
  Future<void> selectCandidate(int index) async {
    final s = state;
    if (s.phase != ImePhase.converting) return;
    final n = s.candidates.length;
    if (n == 0) return;
    final clamped = index.clamp(0, n - 1);
    if (clamped == s.candidateIndex) return;
    await _ensureStarted();
    await _egg.selectCandidate(s.activeSegment, clamped);
    final conv = _conversion;
    _set(
      s.copyWith(
        candidateIndex: clamped,
        displayText: conv == null
            ? s.candidates[clamped]
            : _composeDisplay(conv, s.activeSegment, s.candidates, clamped),
      ),
    );
  }

  /// Shift-K (script toggle): flip the kana script (hiragana⇄katakana) of the
  /// **whole visible preedit** ([displayText]) via [Kana.toggleKana] — e.g.
  /// `でびどう` ⇄ `デビドウ` — in place, in EITHER active phase:
  ///
  ///   * **composing** → flip the raw kana typed so far, so a word can be forced
  ///     to katakana (or back) before it is ever converted;
  ///   * **converting** → flip the whole conversion display, not just the active
  ///     segment's candidate (real Anthy segments a word `で`/`び`/`どう`, so
  ///     flipping one candidate would only re-script a fragment). Matching the
  ///     whole display is both what the user sees selected and what voicelab'
  ///     equivalent does.
  ///
  /// A no-op in idle. Purely client-side — Anthy is not consulted:
  ///   * self-inverse: a second call flips back (kanji runes are left untouched,
  ///     so an all-kanji conversion is a no-op);
  ///   * [preedit] (the raw reading) is left INTACT in both phases, so the flip
  ///     never destroys the reading — **Space** still converts the composing
  ///     reading, and while converting the segment [candidates] are preserved so
  ///     Space re-cycles them (recomposing [displayText], which drops the flip);
  ///   * [commit] (Enter) terminates the mode, emitting the flipped text.
  ///
  /// NB: while composing this deliberately lets [displayText] diverge from
  /// [preedit] (the katakana shown vs. the hiragana reading kept) — the same
  /// display-vs-reading split the converting phase already relies on. The next
  /// [feedKana] rebuilds `displayText` from `preedit`, dropping the flip, which
  /// is correct: typing more means the user is still composing the reading.
  void toggleScript() {
    final s = state;
    if (s.phase == ImePhase.idle) return;
    final toggled = Kana.toggleKana(s.displayText);
    if (toggled == s.displayText) return; // no kana to flip (all-kanji)
    _set(s.copyWith(displayText: toggled));
  }

  /// Shift+Space: cycle the active segment **backward** (wraps). Only meaningful
  /// while converting; a no-op otherwise.
  Future<void> shiftSpace() async {
    if (state.phase != ImePhase.converting) return;
    await _cycle(forward: false);
  }

  /// Move the active-segment cursor to the **next** segment (right), loading
  /// that segment's candidates. Only meaningful while converting; a no-op if
  /// already on the last segment (does not wrap — mirrors most IMEs, where
  /// segment navigation clamps at the ends rather than cycling).
  Future<void> moveSegmentNext() => _moveSegment(1);

  /// Move the active-segment cursor to the **previous** segment (left). Only
  /// meaningful while converting; a no-op if already on segment 0.
  Future<void> moveSegmentPrevious() => _moveSegment(-1);

  Future<void> _moveSegment(int delta) async {
    final s = state;
    if (s.phase != ImePhase.converting) return;
    final conv = _conversion;
    if (conv == null) return;
    final next = s.activeSegment + delta;
    if (next < 0 || next >= conv.segments.length) return;
    await _ensureStarted();
    await _loadSegment(conv, next);
  }

  /// Grow the active segment by one bunsetsu unit ([AnthyEgg.resizeSegment]
  /// with `dir: 0`, the driver's empirically-pinned "grow" direction),
  /// re-segmenting the whole conversion and reloading the active segment's
  /// candidates. Only meaningful while converting; a no-op otherwise.
  Future<void> growSegment() => _resizeSegment(dir: 0);

  /// Shrink the active segment by one bunsetsu unit ([AnthyEgg.resizeSegment]
  /// with a non-zero `dir`), re-segmenting and reloading candidates. Only
  /// meaningful while converting; a no-op otherwise.
  Future<void> shrinkSegment() => _resizeSegment(dir: 1);

  Future<void> _resizeSegment({required int dir}) async {
    final s = state;
    if (s.phase != ImePhase.converting) return;
    await _ensureStarted();
    final conv = await _egg.resizeSegment(s.activeSegment, dir: dir);
    _conversion = conv;
    // Resizing can change the segment count; clamp the active segment into
    // range rather than assuming it still exists.
    final segment = s.activeSegment.clamp(0, conv.segments.length - 1);
    await _loadSegment(conv, segment);
  }

  /// Load [segment]'s candidates from [conv], anchor the index on its current
  /// best (same policy as [_convert]), and publish the recomposed state.
  Future<void> _loadSegment(AnthyConversion conv, int segment) async {
    final cands = await _egg.candidates(segment);
    final best =
        segment < conv.segments.length ? conv.segments[segment].best : '';
    var index = cands.indexOf(best);
    if (index < 0) index = 0;
    _set(
      ImeState(
        phase: ImePhase.converting,
        preedit: state.preedit,
        displayText: _composeDisplay(conv, segment, cands, index),
        candidates: cands,
        candidateIndex: index,
        activeSegment: segment,
      ),
    );
  }

  Future<void> _convert(String hiragana) async {
    await _ensureStarted();
    final conv = await _egg.convert(hiragana);
    _conversion = conv;
    const segment = 0;
    final cands = await _egg.candidates(segment);
    // Anchor the index on the segment's current best so the first Space lands
    // on the converted form the user already sees, then cycles from there.
    final best =
        segment < conv.segments.length ? conv.segments[segment].best : '';
    var index = cands.indexOf(best);
    if (index < 0) index = 0;
    _set(
      ImeState(
        phase: ImePhase.converting,
        preedit: hiragana,
        displayText: _composeDisplay(conv, segment, cands, index),
        candidates: cands,
        candidateIndex: index,
        activeSegment: segment,
      ),
    );
  }

  Future<void> _cycle({required bool forward}) async {
    final s = state;
    final n = s.candidates.length;
    if (n == 0) return;
    final next =
        forward ? (s.candidateIndex + 1) % n : (s.candidateIndex - 1 + n) % n;
    await _ensureStarted();
    await _egg.selectCandidate(s.activeSegment, next);
    final conv = _conversion;
    _set(
      s.copyWith(
        candidateIndex: next,
        displayText: conv == null
            ? s.candidates[next]
            : _composeDisplay(conv, s.activeSegment, s.candidates, next),
      ),
    );
  }

  /// Build the converting-phase [displayText]: every segment's best joined,
  /// with [segment] replaced by `candidates[index]`.
  String _composeDisplay(
    AnthyConversion conv,
    int segment,
    List<String> candidates,
    int index,
  ) {
    final buf = StringBuffer();
    for (var i = 0; i < conv.segments.length; i++) {
      if (i == segment && index >= 0 && index < candidates.length) {
        buf.write(candidates[index]);
      } else {
        buf.write(conv.segments[i].best);
      }
    }
    return buf.toString();
  }

  /// Enter: finalize the conversion (Anthy learns) and return the committed
  /// text. Resets to idle. If called when not converting, returns the current
  /// [displayText] (the raw composing hiragana, or empty) and resets without
  /// touching the driver.
  Future<String> commit() async {
    final s = state;
    final committed = s.displayText;
    if (s.phase == ImePhase.converting) {
      await _ensureStarted();
      await _egg.commit(learn: true);
    }
    _conversion = null;
    _set(ImeState.idle);
    return committed;
  }

  /// Accept the on-screen conversion because the user **typed on**, returning
  /// the accepted text and resetting to idle so the next [feedKana] starts a
  /// fresh composing run. A no-op returning `''` when not converting.
  ///
  /// Distinct from [commit] in exactly one way, and it is the point of the
  /// method: this is **synchronous**. A keystroke cannot wait — [feedKana] is
  /// sync, and the character that triggered the accept has to land in the same
  /// frame as the accepted text or the two arrive out of order. So the phase
  /// flips here and the agent's COMMIT is fired without awaiting its
  /// acknowledgement. [AnthyEgg] serialises its command queue, so that COMMIT
  /// is still ordered ahead of the next CONVERT; only the acknowledgement is
  /// unobserved. Anthy still learns.
  ///
  /// Errors from the deferred COMMIT are swallowed deliberately: the accept has
  /// already been shown to the user and the text is already in the document, so
  /// there is nothing to roll back and nothing the caller could do. A wedged
  /// agent surfaces on the next command, which IS awaited.
  String acceptForTyping() {
    final s = state;
    if (s.phase != ImePhase.converting) return '';
    final committed = s.displayText;
    // Converting implies `start()` already ran, so no `_ensureStarted` await is
    // needed — which is what makes a synchronous accept possible at all.
    unawaited(_egg.commit().catchError((Object _) {}));
    _conversion = null;
    _set(ImeState.idle);
    return committed;
  }

  /// Esc: cancel the conversion and revert to the raw hiragana, returning it.
  /// Resets to idle. Synchronous — it does not finalize with Anthy (the
  /// abandoned group is simply dropped; the next [convert] re-segments fresh).
  String cancel() {
    final raw = state.preedit;
    _conversion = null;
    _set(ImeState.idle);
    return raw;
  }

  /// Discard the active conversion WITHOUT learning, cleanly closing Anthy's
  /// pending context. Returns the raw hiragana that was being composed/converted
  /// (so a caller can keep it if it wants) and resets to idle.
  ///
  /// This is the clean counterpart to [cancel]: where [cancel] drops the group
  /// only on the Dart side — leaving Anthy's converted segments un-finalized —
  /// [discard] issues [AnthyEgg.commit] with `learn: false`, the egg protocol's
  /// mode-1 discard, so the abandoned candidates are released from Anthy's
  /// context and never enter its learning model. Use it wherever an explicit
  /// abandon is wanted (e.g. the second Esc of a two-stage cancel); [cancel]
  /// remains for the cheap synchronous local drop, and is the single-stage Esc
  /// the keymap still dispatches until the session layer owns two-stage cancel.
  ///
  /// While composing there is no live Anthy conversion yet, so this degrades to
  /// a local reset (no egg round-trip) — the same result as [cancel].
  Future<String> discard() async {
    final s = state;
    final raw = s.preedit;
    if (s.phase == ImePhase.converting) {
      await _ensureStarted();
      await _egg.commit(learn: false);
    }
    _conversion = null;
    _set(ImeState.idle);
    return raw;
  }

  /// Backspace:
  ///   * converting → revert to [ImePhase.composing] on the raw hiragana
  ///     (candidates cleared, the conversion dropped).
  ///   * composing → drop the last preedit character (→ idle when it empties).
  ///   * idle → no-op.
  void backspace() {
    final s = state;
    switch (s.phase) {
      case ImePhase.idle:
        return;
      case ImePhase.converting:
        _conversion = null;
        _set(
          ImeState(
            phase: ImePhase.composing,
            preedit: s.preedit,
            displayText: s.preedit,
            candidates: const <String>[],
            candidateIndex: 0,
            activeSegment: 0,
          ),
        );
      case ImePhase.composing:
        final dropped = _dropLastChar(s.preedit);
        if (dropped.isEmpty) {
          _set(ImeState.idle);
        } else {
          _set(
            ImeState(
              phase: ImePhase.composing,
              preedit: dropped,
              displayText: dropped,
              candidates: const <String>[],
              candidateIndex: 0,
              activeSegment: 0,
            ),
          );
        }
    }
  }

  /// Drop the last user-perceived character, honoring surrogate pairs so a
  /// non-BMP code point (rare in hiragana, but correct in general) is removed
  /// whole rather than split into a lone surrogate.
  static String _dropLastChar(String s) {
    if (s.isEmpty) return s;
    final units = s.codeUnits;
    var cut = units.length - 1;
    if (cut > 0 &&
        _isLowSurrogate(units[cut]) &&
        _isHighSurrogate(units[cut - 1])) {
      cut -= 1;
    }
    return s.substring(0, cut);
  }

  static bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;
  static bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;

  /// Explicitly start the egg (otherwise it starts lazily on first conversion).
  Future<void> start() => _ensureStarted();

  /// Tear down: close the egg and the notifier. Safe to call once.
  Future<void> dispose() async {
    _notifier.dispose();
    await _egg.close();
  }
}
