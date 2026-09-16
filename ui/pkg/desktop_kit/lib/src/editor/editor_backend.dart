/// A pluggable backend for a SUBSET of [EmacsBuffer]'s intents, and the
/// request/result shapes it trades with [EmacsBuffer.executeAsync].
///
/// [EmacsBuffer.execute] (the original, synchronous dispatch) is completely
/// unaware this exists — it is, and stays, the unconditional default for
/// every intent and every caller that never sets [EmacsBuffer.editorBackend].
/// [EmacsBuffer.executeAsync] is the ONLY entry point that consults a
/// backend: for an intent [EditorBackend.supports] answers true for, it
/// builds an [EditorBackendRequest] from the CURRENT buffer, awaits
/// [EditorBackend.run], and applies the [EditorBackendResult] back onto the
/// buffer; for every other intent it just calls [EmacsBuffer.execute],
/// unchanged. See [EmacsBuffer.executeAsync]'s doc comment for the full
/// contract, including what a backend does NOT get asked to do (undo/redo
/// bookkeeping stays in [EmacsBuffer] even for a backend-routed edit, so a
/// backend answers "what did this ONE command do", never "manage history").
library;

import 'emacs_buffer.dart';

/// Implemented by a host that wants ONE OR MORE intents driven by something
/// other than [EmacsBuffer]'s own Dart implementation — e.g. a real Emacs
/// Lisp evaluator running out of process. See `textloom`'s `GoElispBackend` for
/// a worked example (the elisp forward-char / beginning-of-line / kill-line /
/// yank / undo primitives, over a per-buffer subprocess).
abstract class EditorBackend {
  /// Whether this backend handles [intentId] itself. Checked on every
  /// [EmacsBuffer.executeAsync] call, so it should be cheap (a `Set.contains`
  /// is the expected shape) and constant for a given id — [EmacsBuffer] does
  /// not re-check mid-dispatch, and a backend that changes its mind about an
  /// id between the `supports` check and the `run` call has undefined
  /// results.
  bool supports(String intentId);

  /// Execute [intentId] against [request]'s buffer state and return the
  /// outcome. Called ONLY for an id [supports] most recently answered true
  /// for.
  ///
  /// A backend need not succeed: [EditorBackendResult.ok] false — for a
  /// transport failure, or because the underlying command itself signalled
  /// (an empty kill ring, an exhausted undo list) — tells
  /// [EmacsBuffer.executeAsync] to fall back to its OWN [EmacsBuffer.execute]
  /// for this one call, so the user gets Dart's native answer instead of
  /// nothing. That fallback is deliberate; see [EmacsBuffer.executeAsync]'s
  /// doc comment for what it costs and what it buys.
  Future<EditorBackendResult> run(
      String intentId, EditorBackendRequest request);
}

/// The buffer state a backend command needs, and nothing else — not the
/// whole [EmacsBuffer] (prompts, buffer switching, macros, the kill-ring
/// browser dialog… are all out of this seam's reach on purpose; a backend
/// answers ONE command against ONE buffer's text/point/mark).
class EditorBackendRequest {
  const EditorBackendRequest({
    required this.bufferId,
    required this.text,
    required this.point,
    required this.mark,
    required this.lastCommand,
  });

  /// Identifies the buffer this request is for, stable across calls for the
  /// same live buffer (see [EmacsBuffer.backendBufferId]) even across a
  /// rename. A backend keyed on a persistent per-buffer resource (a
  /// subprocess, a connection) uses this to route to — or lazily create —
  /// the right one.
  final Object bufferId;

  /// The buffer's current text — THE authority. A backend that keeps its own
  /// mirror (e.g. across a persistent connection, to avoid resending the
  /// whole buffer every keystroke) MUST reconcile against this on every
  /// call, never assume its own mirror is still current: it is current only
  /// when nothing outside this seam touched the buffer since the backend's
  /// last call, and [EmacsBuffer] has on the order of eighty OTHER intents
  /// that can.
  final String text;

  /// 0-based caret offset into [text] (Dart's convention — NOT Emacs's
  /// 1-based `point`; a backend targeting Emacs semantics converts, e.g.
  /// `point = caret + 1`).
  final int point;

  /// The active mark as a raw 0-based offset into [text] — [EmacsBuffer]'s
  /// mark is a single remembered position, not a region; null when no mark
  /// is set.
  final int? mark;

  /// An opaque token naming "the command that immediately preceded this one,
  /// as far as THIS backend is concerned" — empty when there was none.
  /// Mirrors Emacs's `last-command`, which real kill-append/yank-pop
  /// semantics key off (see the elisp runtime's own killring.go header for
  /// why the HOST, not the evaluator, is what sets it). Reset to empty by
  /// ANY intent that did NOT go through this backend — including one this
  /// backend itself declined via `ok: false` — which is what makes an
  /// intervening non-backend command correctly "break the sequence" without
  /// [EmacsBuffer] knowing anything about the backend's own vocabulary.
  final String lastCommand;
}

/// What a backend did, translated back into terms [EmacsBuffer] understands.
class EditorBackendResult {
  const EditorBackendResult({
    required this.ok,
    this.text,
    this.point,
    this.markSet = false,
    this.markValue,
    this.thisCommand = '',
    this.status,
  });

  /// A definitive negative answer: the backend either could not reach its
  /// resource, or the underlying command itself failed the way a REAL
  /// command can (Kill ring is empty; No further undo information). Either
  /// way [text]/[point]/[markSet] are ignored and
  /// [EmacsBuffer.executeAsync] falls back to [EmacsBuffer.execute] for this
  /// one call.
  static const EditorBackendResult notOk = EditorBackendResult(ok: false);

  /// False means: no successful outcome — see [notOk]. True means the
  /// fields below describe it.
  final bool ok;

  /// The buffer's new text, or null to leave it unchanged (a successful
  /// command that happens not to have mutated anything, e.g. a motion at a
  /// buffer boundary that clamped to where it already was).
  final String? text;

  /// The new 0-based caret offset, or null to leave it unchanged.
  final int? point;

  /// Whether the backend has an opinion about the mark at all. Every intent
  /// in the arm this class was built for DOES have one (it always mirrors
  /// the evaluator's own notion of `(mark)`, set or cleared) — this flag is
  /// future-proofing for a backend whose commands never touch the mark,
  /// where `markSet: false` leaves [EmacsBuffer]'s mark exactly as it was
  /// rather than forcing every result to restate it.
  final bool markSet;

  /// The mark's new 0-based offset when [markSet] is true and the mark is
  /// set; null (with [markSet] true) means "the backend says the mark is now
  /// UNSET" — a real, distinct outcome (e.g. after a command that clears it),
  /// not "no opinion".
  final int? markValue;

  /// The token to feed back as the NEXT call's [EditorBackendRequest.lastCommand].
  /// Empty when this command does not establish one a follow-on command
  /// would care about (most commands, in Emacs terms — only the kill/yank
  /// family and undo do).
  final String thisCommand;

  /// A human-readable status line, mirroring what every [EmacsBuffer]
  /// dispatch case sets on `status` (e.g. "Killed line"). Null lets the
  /// caller fall back to its own default (id-shaped or a registry label,
  /// host's choice) the same way an unhandled [EmacsBuffer.execute] id does.
  final String? status;
}
