// Shared, headless *editing-session* model for the kana→kanji preedit.
//
// [ImeController] owns the CONVERSION state machine (convert / cycle / segment
// nav / commit / cancel over an Anthy egg). It deliberately knows nothing about
// WHERE the preedit sits in a document, how the highlighted region is tracked,
// or how a commit/cancel splices real text. Every consumer (textloom, word-bank,
// voicelab) re-invented exactly that missing layer — divergently, and with the
// region-tracking bugs that motivated this file (a region that grew across
// conversions, an Enter that left a stray newline, two uncoordinated splice
// paths). [PreeditSession] owns that layer ONCE:
//
//   * it keeps the preedit as a SINGLE contiguous region [start, end) in the
//     host's text, ending at the caret — no second length counter to drift;
//   * it inverts rendering behind [PreeditHost]: the session computes a
//     [PreeditSplice] (delete N before the caret, insert S) and the consumer
//     applies it to ITS OWN text model (an EmacsBuffer, a TextEditingController,
//     …). The session never imports a widget;
//   * terminal ops ([commit] / [cancel] / [discard]) emit one final splice and
//     reset — Enter commits AND exits, Esc is two-stage (converting reverts to
//     the reading and STAYS composing; a second Esc abandons);
//   * it surrenders (re-anchors without corrupting text) if the buffer changed
//     underneath it — a caret move away, or an external edit to the region.
//
// The session accepts input at two levels:
//   * [feed] — raw per-keystroke romaji. It owns a [RomajiInputBuffer], moves
//     finalised kana into the controller, and keeps the un-finalised tail in
//     [PreeditRegion.pendingRomajiLength] so the highlighted region spans
//     "finalised kana + romaji tail" from the very first keystroke.
//   * [feedKana] — already-finalised kana, for a host that resolves romaji
//     itself (the same granularity [ImeController.feedKana] accepts).
library;

import 'package:flutter/foundation.dart';

import '../kana/romaji_input_buffer.dart';
import 'anthy_egg.dart';
import 'ime_controller.dart';

/// Lifecycle phase of the shared preedit — a session-level echo of [ImePhase].
enum PreeditPhase {
  /// No active region.
  idle,

  /// Raw kana is accumulating (romaji→kana); Anthy not yet consulted.
  composing,

  /// Converted to kanji; the user is cycling candidates / segments.
  converting,
}

/// The active preedit's placement in the host's text: a single contiguous span
/// `[start, start + length)` whose content is [text] and whose end is the caret.
///
/// The trailing [pendingRomajiLength] characters are un-finalised romaji (e.g. a
/// lone `k` before it resolves to か) — part of the highlighted region, but not
/// yet kana. [PreeditSession.feed] (raw per-keystroke romaji) populates it; it
/// stays 0 when a host drives [PreeditSession.feedKana] with finalised kana.
@immutable
class PreeditRegion {
  /// Create a region anchored at [start] holding [text].
  const PreeditRegion({
    required this.start,
    required this.text,
    this.pendingRomajiLength = 0,
  });

  /// The empty (idle) region.
  static const PreeditRegion empty = PreeditRegion(start: 0, text: '');

  /// Offset of the region's first character in the host buffer.
  final int start;

  /// The rendered preedit text (what the host shows highlighted).
  final String text;

  /// How many trailing characters of [text] are un-finalised romaji.
  final int pendingRomajiLength;

  /// Character length of the region (== `text.length`).
  int get length => text.length;

  /// One-past-the-last offset — where the caret sits while the region is active.
  int get end => start + length;

  /// Whether the region holds nothing.
  bool get isEmpty => text.isEmpty;

  /// A copy with the given fields replaced.
  PreeditRegion copyWith(
          {int? start, String? text, int? pendingRomajiLength}) =>
      PreeditRegion(
        start: start ?? this.start,
        text: text ?? this.text,
        pendingRomajiLength: pendingRomajiLength ?? this.pendingRomajiLength,
      );

  @override
  bool operator ==(Object other) =>
      other is PreeditRegion &&
      other.start == start &&
      other.text == text &&
      other.pendingRomajiLength == pendingRomajiLength;

  @override
  int get hashCode => Object.hash(start, text, pendingRomajiLength);

  @override
  String toString() =>
      'PreeditRegion([$start,$end) "$text" pending=$pendingRomajiLength)';
}

/// Why the session is asking the host to splice — lets a host pick its own undo
/// / macro behaviour (coalesce intermediate edits, record one self-insert on
/// commit) without understanding IME internals.
enum PreeditSpliceKind {
  /// Intermediate composing edit (romaji→kana). Coalesce into one undo step.
  compose,

  /// Conversion-render edit (candidate cycle / segment nav / script flip).
  convert,

  /// Final commit — [PreeditSplice.insert] is the committed text; the host
  /// records one self-insert macro step and the region clears.
  commit,

  /// The preedit was abandoned — the region clears (insert is empty).
  cancel,
}

/// One edit the host must apply to its own text model: delete [deleteBefore]
/// characters immediately before the caret (== the region end), then insert
/// [insert]. Maps 1:1 onto `EmacsBuffer.replaceBeforeCaret(deleteBefore,
/// insert)` and onto a `TextEditingController` splice.
@immutable
class PreeditSplice {
  /// Create a splice.
  const PreeditSplice({
    required this.kind,
    required this.deleteBefore,
    required this.insert,
  });

  /// Why this splice was emitted.
  final PreeditSpliceKind kind;

  /// Characters to delete immediately before the caret before inserting.
  final int deleteBefore;

  /// Text to insert at the caret after the deletion.
  final String insert;

  /// Whether this splice ends the preedit (commit or cancel).
  bool get isTerminal =>
      kind == PreeditSpliceKind.commit || kind == PreeditSpliceKind.cancel;

  @override
  String toString() =>
      'PreeditSplice(${kind.name}, -$deleteBefore, +"$insert")';
}

/// The text model a [PreeditSession] drives. A consumer adapts its own buffer to
/// this interface; the session never touches widgets.
abstract class PreeditHost {
  /// The host buffer's current full text.
  String get text;

  /// The current caret offset. An active region always ends here.
  int get caret;

  /// Apply [splice] at the caret. After this returns, [text] and [caret] must
  /// reflect it (delete then insert, caret after the inserted text).
  void applyPreeditSplice(PreeditSplice splice);

  /// Return the `region.length` characters the host currently holds starting at
  /// `region.start`. Used to detect that the buffer changed underneath the
  /// session (a stale region) so it can re-anchor rather than corrupt text.
  String readRegion(PreeditRegion region);
}

/// The result of a terminal session op. [committed] is set by [commit] (the
/// finalised text inserted); [reverted] is set by [discard] / the abandoning
/// stage of [cancel] (the raw reading the group held). Both null for a no-op or
/// the non-terminal (still-composing) stage of [cancel].
@immutable
class PreeditOutcome {
  /// Create an outcome.
  const PreeditOutcome({this.committed, this.reverted});

  /// The no-op / still-active outcome.
  static const PreeditOutcome none = PreeditOutcome();

  /// The committed text, if this op finalised the preedit.
  final String? committed;

  /// The raw reading, if this op abandoned the preedit.
  final String? reverted;

  @override
  String toString() =>
      'PreeditOutcome(committed: $committed, reverted: $reverted)';
}

/// Observable session view-state: the mapped [phase], the current [region], and
/// the conversion candidates (pass-through from [ImeController]).
@immutable
class PreeditState {
  /// Create a state.
  const PreeditState({
    required this.phase,
    required this.region,
    required this.candidates,
    required this.candidateIndex,
    required this.activeSegment,
  });

  /// The idle state — no active region.
  static const PreeditState idle = PreeditState(
    phase: PreeditPhase.idle,
    region: PreeditRegion.empty,
    candidates: <String>[],
    candidateIndex: 0,
    activeSegment: 0,
  );

  /// Lifecycle phase.
  final PreeditPhase phase;

  /// The active region (empty when idle).
  final PreeditRegion region;

  /// Candidate strings for the active segment (empty unless converting).
  final List<String> candidates;

  /// Index of the selected candidate.
  final int candidateIndex;

  /// The segment being cycled.
  final int activeSegment;

  /// Whether a region is active.
  bool get isActive => phase != PreeditPhase.idle;

  @override
  bool operator ==(Object other) =>
      other is PreeditState &&
      other.phase == phase &&
      other.region == region &&
      listEquals(other.candidates, candidates) &&
      other.candidateIndex == candidateIndex &&
      other.activeSegment == activeSegment;

  @override
  int get hashCode => Object.hash(
        phase,
        region,
        Object.hashAll(candidates),
        candidateIndex,
        activeSegment,
      );

  @override
  String toString() =>
      'PreeditState(${phase.name}, $region, cands=$candidates@$candidateIndex, '
      'seg=$activeSegment)';
}

/// Headless editing-session model wrapping an [ImeController]: it tracks the
/// single preedit region and translates every conversion transition into a
/// [PreeditSplice] the [PreeditHost] applies to its own text.
///
/// Construct with a host and a controller (inject a scripted [AnthyEgg] in tests
/// via `PreeditSession(host, ImeController(AnthyEgg(fake)))`). Listen to
/// [notifier] for view-state, or read [state] synchronously.
class PreeditSession {
  /// Wrap [_ime], splicing into [_host].
  PreeditSession(this._host, this._ime);

  /// Convenience: build the controller from an [egg].
  PreeditSession.overEgg(this._host, AnthyEgg egg) : _ime = ImeController(egg);

  final PreeditHost _host;
  final ImeController _ime;

  final ValueNotifier<PreeditState> _notifier =
      ValueNotifier<PreeditState>(PreeditState.idle);

  /// Listenable view-state.
  ValueNotifier<PreeditState> get notifier => _notifier;

  /// The current view-state (synchronous read).
  PreeditState get state => _notifier.value;

  /// The underlying conversion controller (candidate list, segment state) for a
  /// host that renders a candidate panel. Drive transitions through the session,
  /// not this, so the region stays in sync.
  ImeController get controller => _ime;

  /// Whether a region is currently active in the host.
  bool _active = false;

  /// The tracked region (valid only while [_active]).
  PreeditRegion _region = PreeditRegion.empty;

  /// Romaji→kana engine owning the un-finalised tail. Finalised kana is fed into
  /// [_ime]; the pending raw stays here, mirrored as text in [_pendingText].
  final RomajiInputBuffer _romaji = RomajiInputBuffer();

  /// The current pending raw romaji (the un-finalised tail), rendered AFTER the
  /// finalised kana so the region spans the full preedit. Held as text because
  /// the engine exposes only its length; kept in lock-step with [_romaji].
  String _pendingText = '';

  // --- Input --------------------------------------------------------------

  /// Feed one raw typed [char] to the romaji engine. Finalised kana moves into
  /// the composing preedit; the un-finalised tail stays in the region as
  /// [PreeditRegion.pendingRomajiLength] trailing characters — so the highlight
  /// spans "finalised kana + romaji tail" from the very first keystroke.
  ///
  /// Returns whether [char] was consumed as romaji. A non-letter (digit,
  /// punctuation, …) is NOT consumed: any pending tail is finalised into the
  /// preedit and `false` is returned so the caller inserts [char] itself (or
  /// commits first). Space / Enter / Esc are commands — route them to [space] /
  /// [commit] / [cancel], never here.
  bool feed(String char) {
    _guardStale();
    final int code = char.isEmpty ? -1 : char.codeUnitAt(0);
    final bool isLetter =
        (code >= 0x61 && code <= 0x7A) || (code >= 0x41 && code <= 0x5A);
    if (!isLetter) {
      final bool hadPending = _romaji.hasPending;
      _flushPending();
      if (hadPending) _render(PreeditSpliceKind.compose);
      return false;
    }
    // A letter typed over a live conversion accepts it and opens a new run —
    // BEFORE the romaji buffer sees the character, so the accepted text is
    // spliced first and the new region opens at the caret past it.
    _acceptConversionForTyping();
    final RomajiResult r = _romaji.feed(char);
    // r.insert == <finalised kana><new pending raw>; the new pending is exactly
    // the last pendingLength characters, so the rest is what just finalised.
    final int pending = _romaji.pendingLength;
    final String finalized = r.insert.substring(0, r.insert.length - pending);
    _pendingText = r.insert.substring(r.insert.length - pending);
    if (finalized.isNotEmpty) _ime.feedKana(finalized);
    _render(PreeditSpliceKind.compose);
    return true;
  }

  /// Feed already-finalised [kana] into the composing preedit (for a host that
  /// resolves romaji itself). Grows the single active region — or, over a live
  /// conversion, accepts it and starts a new run (see
  /// [_acceptConversionForTyping]).
  void feedKana(String kana) => _step(() {
        _acceptConversionForTyping();
        _ime.feedKana(kana);
      }, PreeditSpliceKind.compose);

  /// Space: convert (first press) or cycle the active segment forward. Finalises
  /// any pending romaji tail into the reading first, so Space converts the whole
  /// word rather than leaving a raw tail behind.
  Future<void> space() async {
    _guardStale();
    _flushPending();
    await _ime.space();
    _render(PreeditSpliceKind.convert);
  }

  /// Shift+Space: cycle the active segment backward.
  Future<void> shiftSpace() =>
      _stepAsync(_ime.shiftSpace, PreeditSpliceKind.convert);

  /// Select an absolute candidate [index] (candidate-panel click).
  Future<void> selectCandidate(int index) =>
      _stepAsync(() => _ime.selectCandidate(index), PreeditSpliceKind.convert);

  /// Move the active-segment cursor right.
  Future<void> moveSegmentNext() =>
      _stepAsync(_ime.moveSegmentNext, PreeditSpliceKind.convert);

  /// Move the active-segment cursor left.
  Future<void> moveSegmentPrevious() =>
      _stepAsync(_ime.moveSegmentPrevious, PreeditSpliceKind.convert);

  /// Grow the active segment.
  Future<void> growSegment() =>
      _stepAsync(_ime.growSegment, PreeditSpliceKind.convert);

  /// Shrink the active segment.
  Future<void> shrinkSegment() =>
      _stepAsync(_ime.shrinkSegment, PreeditSpliceKind.convert);

  /// Shift+K: flip the kana script of the live preedit in place (composing or
  /// converting), preserving the reading — see [ImeController.toggleScript].
  void toggleScript() => _step(_ime.toggleScript, PreeditSpliceKind.convert);

  /// Backspace: a pending romaji tail loses its last raw character first; else
  /// while converting revert to the composing reading, and while composing drop
  /// the last kana (clearing the region when it empties).
  void backspace() {
    _guardStale();
    if (_romaji.hasPending) {
      _romaji.backspace();
      _pendingText = _pendingText.isEmpty
          ? ''
          : _pendingText.substring(0, _pendingText.length - 1);
      _render(PreeditSpliceKind.compose);
      return;
    }
    _ime.backspace();
    _render(PreeditSpliceKind.compose);
  }

  // --- Terminal ops -------------------------------------------------------

  /// Enter: commit the preedit (converting → Anthy learns; composing → the raw
  /// kana) and EXIT. Emits one commit splice replacing the region with the
  /// finalised text, then resets to idle.
  Future<PreeditOutcome> commit() async {
    _guardStale();
    _flushPending(); // fold a trailing romaji tail into the committed reading
    if (!_ime.state.isActive) {
      _resetIdle();
      return PreeditOutcome.none;
    }
    final String committed = await _ime.commit();
    if (_active) {
      _host.applyPreeditSplice(PreeditSplice(
        kind: PreeditSpliceKind.commit,
        deleteBefore: _region.length,
        insert: committed,
      ));
    }
    _resetIdle();
    return PreeditOutcome(committed: committed);
  }

  /// Commit a NON-converting preedit **synchronously**, returning its outcome —
  /// or null when the preedit is converting and therefore needs the async
  /// [commit] (only a conversion has to round-trip Anthy so it can learn).
  ///
  /// This exists because a host's "something else is about to happen" choke
  /// point is synchronous: it flushes the preedit and then runs a command, in
  /// that order. [commit] applies its splice only *after* `await`-ing the
  /// controller — and that await yields even while composing, where no egg
  /// round-trip happens at all — so a caller that cannot await would run its
  /// command BEFORE the splice landed, and [_guardStale] (evaluated before the
  /// await) cannot catch a caret move that happens after it. The deferred splice
  /// would then write at a moved caret and corrupt text.
  ///
  /// A composing commit needs nothing from the driver: the committed text is
  /// already [ImeState.displayText], and the abandoned group carries no learning
  /// worth recording — so it is finalised locally ([ImeController.cancel]) and
  /// spliced immediately.
  ///
  /// Usage in a synchronous choke point:
  /// ```dart
  /// final PreeditOutcome? done = session.commitSync();
  /// if (done == null) {
  ///   // Converting: must await, so defer the command to preserve ordering.
  ///   unawaited(session.commit().then((_) => runCommand()));
  /// } else {
  ///   runCommand(); // already spliced — ordering intact
  /// }
  /// ```
  PreeditOutcome? commitSync() {
    _guardStale();
    _flushPending();
    final ImeState s = _ime.state;
    if (!s.isActive) {
      _resetIdle();
      return PreeditOutcome.none;
    }
    if (s.phase == ImePhase.converting) return null; // caller must await commit
    final String committed = s.displayText;
    if (_active) {
      _host.applyPreeditSplice(PreeditSplice(
        kind: PreeditSpliceKind.commit,
        deleteBefore: _region.length,
        insert: committed,
      ));
    }
    // Local reset only — a composing group has nothing for Anthy to learn.
    _ime.cancel();
    _resetIdle();
    return PreeditOutcome(committed: committed);
  }

  /// Esc — two-stage cancel:
  ///   * converting → revert to the composing reading and STAY active (stage 1);
  ///   * composing / idle → abandon the preedit entirely (stage 2, [discard]).
  ///
  /// So a first Esc undoes a conversion without leaving the group; a second Esc
  /// drops it. Returns [PreeditOutcome.none] for stage 1 (still active).
  Future<PreeditOutcome> cancel() async {
    _guardStale();
    // Stage 0: an un-finalised romaji TAIL is dropped on its own — the raw
    // letters are discarded (never converted) and the finalised kana beside
    // them survives. Only once no tail remains does Esc act on the group.
    if (_romaji.hasPending) {
      _romaji.cancel();
      _pendingText = '';
      _render(PreeditSpliceKind.compose);
      return PreeditOutcome.none;
    }
    if (_ime.state.phase == ImePhase.converting) {
      _ime.backspace(); // converting → composing (back to the raw reading)
      _render(PreeditSpliceKind.convert);
      return PreeditOutcome.none;
    }
    return discard();
  }

  /// Abandon the preedit: discard the conversion Anthy-cleanly
  /// ([ImeController.discard]), clear the region, and reset to idle. Returns the
  /// raw reading in [PreeditOutcome.reverted].
  Future<PreeditOutcome> discard() async {
    _guardStale();
    if (!_ime.state.isActive) {
      _resetIdle();
      return PreeditOutcome.none;
    }
    final String raw = await _ime.discard();
    if (_active) {
      _host.applyPreeditSplice(PreeditSplice(
        kind: PreeditSpliceKind.cancel,
        deleteBefore: _region.length,
        insert: '',
      ));
    }
    _resetIdle();
    return PreeditOutcome(reverted: raw);
  }

  // --- Rendering ----------------------------------------------------------

  /// Guard-then-drive a synchronous controller op, re-rendering the region.
  void _step(void Function() op, PreeditSpliceKind kind) {
    _guardStale();
    op();
    _render(kind);
  }

  /// Guard-then-drive an asynchronous controller op, re-rendering the region.
  Future<void> _stepAsync(
    Future<void> Function() op,
    PreeditSpliceKind kind,
  ) async {
    _guardStale();
    await op();
    _render(kind);
  }

  /// If the host buffer moved underneath us (caret off the region end, or the
  /// region's characters edited away), abandon our preedit state so the incoming
  /// op starts a FRESH region. The host text is authoritative — we do not try to
  /// delete or rewrite it, we just stop tracking the stale span. Runs BEFORE the
  /// controller op, so a stale [feedKana] never appends to a dropped reading and
  /// then re-inserts the whole thing (the bug this guard exists to prevent).
  ///
  /// Uses the synchronous local [ImeController.cancel] (not [discard]) so the
  /// guard stays sync and callable from [feedKana] / [toggleScript] / etc.
  void _guardStale() {
    if (_active && _isStale()) {
      _ime.cancel();
      _romaji.cancel();
      _pendingText = '';
      _active = false;
      _region = PreeditRegion.empty;
    }
  }

  /// The user typed a character while a conversion was on screen: accept it and
  /// close the region, so the caller's own render opens a FRESH one at the
  /// caret. A no-op when not converting.
  ///
  /// This is what every mainstream IME does — typing on means "yes, that
  /// conversion", not "edit inside it". Without it the character was consumed
  /// by the input path (so the host did not insert it either) and then dropped
  /// by [ImeController.feedKana], which ignores input while converting: the
  /// keystroke produced nothing at all, and a long phrase came out as several
  /// unrelated conversions with kana missing between them.
  ///
  /// Emits a [PreeditSpliceKind.commit] splice, so a host that coalesces
  /// composing edits into one undo step records the accepted conversion as its
  /// own step — the same treatment Enter gives it.
  void _acceptConversionForTyping() {
    if (_ime.state.phase != ImePhase.converting) return;
    final String accepted = _ime.acceptForTyping();
    if (_active) {
      _host.applyPreeditSplice(PreeditSplice(
        kind: PreeditSpliceKind.commit,
        deleteBefore: _region.length,
        insert: accepted,
      ));
    }
    _active = false;
    _region = PreeditRegion.empty;
  }

  /// Finalise any pending romaji tail into the composing preedit (a trailing
  /// lone `n` → ん; other partial fragments pass through raw), clearing the tail.
  void _flushPending() {
    if (!_romaji.hasPending) return;
    final String flushed = _romaji.flush();
    _pendingText = '';
    if (flushed.isNotEmpty) _ime.feedKana(flushed);
  }

  /// Reconcile the host region with [ImeController.state.displayText] after a
  /// non-terminal transition, emitting exactly one splice. Opens a region at the
  /// caret on the first non-empty render and clears it when the render empties.
  void _render(PreeditSpliceKind kind) {
    final String rendered = _rendered();

    if (!_active) {
      if (rendered.isEmpty) {
        _publish();
        return;
      }
      _region = PreeditRegion(start: _host.caret, text: '');
      _active = true;
    }

    _host.applyPreeditSplice(PreeditSplice(
      kind: kind,
      deleteBefore: _region.length,
      insert: rendered,
    ));

    if (rendered.isEmpty) {
      _active = false;
      _region = PreeditRegion.empty;
    } else {
      _region = _region.copyWith(
        start: _host.caret - rendered.length,
        text: rendered,
        pendingRomajiLength:
            _ime.state.phase == ImePhase.converting ? 0 : _pendingText.length,
      );
    }
    _publish();
  }

  /// The full preedit render: the controller's display text (finalised kana, or
  /// the conversion display) followed by the un-finalised romaji tail while
  /// composing. Converting has no tail — romaji can't be typed then.
  String _rendered() {
    final ImeState s = _ime.state;
    if (s.phase == ImePhase.converting) return s.displayText;
    return s.displayText + _pendingText;
  }

  /// Whether the tracked region no longer matches the host — the caret moved off
  /// the region end, or the region's characters were edited under us.
  bool _isStale() {
    if (!_active) return false;
    if (_host.caret != _region.end) return true;
    return _host.readRegion(_region) != _region.text;
  }

  void _resetIdle() {
    _romaji.cancel();
    _pendingText = '';
    _active = false;
    _region = PreeditRegion.empty;
    _publish();
  }

  void _publish() {
    final ImeState s = _ime.state;
    _notifier.value = PreeditState(
      phase: _sessionPhase(),
      region: _active ? _region : PreeditRegion.empty,
      candidates: s.candidates,
      candidateIndex: s.candidateIndex,
      activeSegment: s.activeSegment,
    );
  }

  /// The session phase. A pending romaji tail with the controller still idle (a
  /// lone `k` before its kana resolves) is COMPOSING at the session level, even
  /// though [ImeController] has seen no finalised kana yet.
  PreeditPhase _sessionPhase() {
    final ImePhase p = _ime.state.phase;
    if (p == ImePhase.idle && _pendingText.isNotEmpty) {
      return PreeditPhase.composing;
    }
    return _mapPhase(p);
  }

  PreeditPhase _mapPhase(ImePhase p) => switch (p) {
        ImePhase.idle => PreeditPhase.idle,
        ImePhase.composing => PreeditPhase.composing,
        ImePhase.converting => PreeditPhase.converting,
      };

  /// Tear down the controller and notifier. Safe to call once.
  Future<void> dispose() async {
    _notifier.dispose();
    await _ime.dispose();
  }
}
