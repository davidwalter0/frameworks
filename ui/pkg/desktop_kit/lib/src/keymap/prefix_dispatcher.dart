// C-x prefix chord state machine.
//
// Ported verbatim from voicelab and notekeep. Pure domain code — no Flutter
// types — so the dispatcher is unit-testable without a widget tree.
library;

/// Logical editor commands the C-x prefix can produce.
///
/// Kept Flutter-free so the dispatcher is a pure state machine.
enum EditorCommand {
  /// A key was consumed as part of a prefix chord; no command yet.
  none,

  /// C-x was pressed and we are now waiting for the second key.
  prefixPending,

  /// C-x C-s — save the current buffer.
  saveBuffer,

  /// C-x C-f — open / find a file.
  findFile,

  /// C-x C-x — exchange point and mark.
  exchangePointAndMark,

  /// C-x b — switch buffer.
  switchBuffer,

  /// C-x k — kill (close) the current buffer.
  killBuffer,

  /// C-x h — mark the whole buffer.
  markWholeBuffer,

  /// C-x C-p — mark the page around point (bounded by form feeds).
  markPage,

  /// The chord was unrecognized; the dispatcher reset to idle. The caller
  /// may beep or show `C-x <key> is undefined`.
  unknown,
}

/// Keys the dispatcher understands as the *second* stroke of a C-x chord.
///
/// The widget layer maps raw [LogicalKeyboardKey] events onto these so the
/// domain stays free of Flutter types.
enum PrefixKey { ctrlS, ctrlF, ctrlX, ctrlP, letterB, letterH, letterK }

/// States of the prefix state machine.
enum PrefixPhase { idle, afterCtrlX }

/// A small state machine implementing Emacs C-x prefix chords:
///
/// ```
/// idle --C-x--> afterCtrlX --(key)--> dispatch (and back to idle)
/// ```
///
/// Pure and headlessly testable. The editor feeds it [pressCtrlX] when C-x
/// is seen and [pressKey] for the following stroke; the returned
/// [EditorCommand] drives the action layer.
///
/// **Deprecated.** Use [SequenceMatcher] for new code.  [SequenceMatcher] is
/// a config-driven trie over any [KeyChordSequence] bindings — not limited to
/// the C-x prefix — and integrates directly with [KeymapConfig.sequenceBindings]
/// and [KeymapRegistry].  [PrefixDispatcher] is retained for voicelab until
/// chain step 3 rewires it; its behaviour is unchanged.
@Deprecated(
  'Use SequenceMatcher instead. '
  'PrefixDispatcher is a hardcoded C-x state machine; SequenceMatcher is the '
  'config-driven replacement that handles any multi-stroke binding. '
  'PrefixDispatcher will be removed once voicelab migrates in step 3.',
)
class PrefixDispatcher {
  PrefixPhase _phase = PrefixPhase.idle;

  /// Current state of the state machine.
  PrefixPhase get phase => _phase;

  /// True when a C-x has been pressed and we are waiting for the second key.
  bool get isWaiting => _phase == PrefixPhase.afterCtrlX;

  /// C-x pressed. Enters (or re-enters) the waiting state. Returns
  /// [EditorCommand.prefixPending] so the UI can show "C-x-" in a minibuffer.
  EditorCommand pressCtrlX() {
    _phase = PrefixPhase.afterCtrlX;
    return EditorCommand.prefixPending;
  }

  /// A second stroke arrived. If we are waiting after C-x, dispatch the chord
  /// and return to idle; otherwise return [EditorCommand.none] (the key was
  /// not part of a chord and should be handled normally elsewhere).
  EditorCommand pressKey(PrefixKey key) {
    if (_phase != PrefixPhase.afterCtrlX) {
      return EditorCommand.none;
    }
    _phase = PrefixPhase.idle;
    switch (key) {
      case PrefixKey.ctrlS:
        return EditorCommand.saveBuffer;
      case PrefixKey.ctrlF:
        return EditorCommand.findFile;
      case PrefixKey.ctrlX:
        return EditorCommand.exchangePointAndMark;
      case PrefixKey.ctrlP:
        return EditorCommand.markPage;
      case PrefixKey.letterB:
        return EditorCommand.switchBuffer;
      case PrefixKey.letterH:
        return EditorCommand.markWholeBuffer;
      case PrefixKey.letterK:
        return EditorCommand.killBuffer;
    }
  }

  /// Abort a pending prefix (e.g. on C-g or any non-chord key). Resets to
  /// idle and returns whether a prefix was actually pending.
  bool cancel() {
    final wasWaiting = _phase == PrefixPhase.afterCtrlX;
    _phase = PrefixPhase.idle;
    return wasWaiting;
  }
}
