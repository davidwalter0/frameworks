// A pure, headless Emacs-style text buffer model: caret motion, mark/region,
// kill-ring integration, undo/redo, and a small set of Emacs editing
// commands — all operating on a plain Dart String with no Flutter
// dependency. Intended as the model layer behind an editor widget; the
// widget owns the TextEditingController and calls [execute] per intent id.
//
// The heavier commands are not implemented here: search/replace lives in
// `emacs_search.dart`, registers + keyboard macros in `emacs_registers.dart`,
// and the pure text transformations (comment-dwim, zap, transpose, goto-line,
// rectangles) in `emacs_edit_ops.dart`. This file is the glue that gives them
// a buffer to act on — undo, mark adjustment, kill-ring and status.
library;

import 'dart:convert' show utf8;

import 'package:meta/meta.dart' show visibleForTesting;

import '../keymap/kill_ring.dart';
import '../keymap/mark_state.dart';
import '../keymap/text_motions.dart';
import '../org_edit/org_structure.dart' show OrgEdit;
import 'editor_backend.dart';
import 'emacs_completion.dart';
import 'emacs_edit_ops.dart';
import 'emacs_registers.dart';
import 'emacs_search.dart';
import 'swiper.dart';
import 'text_fill.dart';

/// Caret rendering shape a host UI might use — purely descriptive, the model
/// itself never changes this.
enum CursorShape { bar, block, hollowBlock, underline }

/// The pending minibuffer interaction, if any. Each kind decides what
/// [EmacsBuffer.promptChar] does with a keystroke and what
/// [EmacsBuffer.promptAccept] commits.
enum _PromptKind {
  /// C-s — incremental, re-searching on every keystroke.
  isearchForward,

  /// C-r — as [isearchForward] but scanning backwards.
  isearchBackward,

  /// C-M-s — incremental *regexp* search, forward.
  isearchForwardRegexp,

  /// C-M-r — incremental *regexp* search, backward.
  isearchBackwardRegexp,

  /// M-% / C-M-% first leg: the string (or regexp) to replace.
  queryReplaceFrom,

  /// M-% / C-M-% second leg: what to replace it with.
  queryReplaceWith,

  /// M-g g — a 1-indexed line number.
  gotoLine,

  /// M-z — completes on the first character typed (no RET).
  zapToChar,

  /// C-x r s — completes on the first character typed (the register name).
  copyToRegister,

  /// C-x r i — completes on the first character typed (the register name).
  insertRegister,

  /// C-x b — a buffer name to switch to (creating it if it does not exist).
  switchBuffer,

  /// C-x k — a buffer name to kill (empty accepts the current buffer).
  killBuffer,

  /// M-s s — swiper: a live filtered line search. Each keystroke re-filters
  /// (see [promptChar]); RET lands, C-g restores the pre-swiper point.
  swiper,

  /// M-s o — occur: a pattern to list matching lines for. Only opened when
  /// there is no previous search string to default to (see [_pendingOccurQuery]).
  occurPattern,

  /// M-x — execute-extended-command: a command name, TAB-completed against
  /// whatever candidate provider the host installs via
  /// [EmacsBuffer.setCompletionProvider]. RET stashes the accepted id in
  /// [EmacsBuffer.takePendingCommand] for the host to execute.
  executeCommand,
}

/// One buffer in the buffer list: a LIVE object, not a snapshot.
///
/// [EmacsBuffer] holds these in a name-keyed map and delegates its own
/// `text`/`caret` straight through to the current one, so editing the current
/// buffer edits this object in place. Nothing is copied in on a switch or
/// copied out on a save — the two directions of that copy were the source of
/// "switching buffers loses the last edit", since either half going stale
/// silently overwrote live state.
///
/// State that is buffer-local in Emacs belongs HERE as it is migrated: text,
/// caret, the mark, major mode, default directory, the modified flag,
/// visited file and search hits today; undo/redo is the one still pending —
/// see [EmacsBuffer._undo]. State that is genuinely session-wide (the kill
/// ring, registers, the minibuffer prompt) stays on [EmacsBuffer].
class Buffer {
  Buffer(this.name, this.text, this.caret);

  /// This buffer's name (Emacs `buffer-name`) — the identity `C-x b`, the
  /// buffer list and the mode line all key on.
  ///
  /// The BUFFER owns its name; [EmacsBuffer]'s name-keyed map is an INDEX over
  /// these, not the place identity lives. That inversion is the point: while
  /// the name WAS the identity, everything holding a buffer held a name, and a
  /// name expires. `renameBuffer` re-keys the index and updates this field on
  /// the SAME object, so a window (or any other holder of a [Buffer]) keeps
  /// pointing at the right buffer across a rename instead of silently
  /// dangling — the failure behind "a rename reverted an org buffer to
  /// fundamental" and "a split window went blank".
  ///
  /// Mutable, and written ONLY by [EmacsBuffer.renameBuffer], which changes it
  /// and the index key together. Writing it directly desynchronises the two
  /// and is what [EmacsBuffer.isLive] would then report as a dead buffer.
  String name;
  String text;
  int caret;

  /// The mark and mark ring for THIS buffer — Emacs `mark-marker` is
  /// buffer-local. A mark offset indexes THIS text and no other, so sharing
  /// one across buffers describes a region in whichever buffer happens to be
  /// current: the same character offsets appear selected in two windows at
  /// once.
  final MarkState mark = MarkState();

  /// The most recent yank / yank-pop insertion range, so a following yank-pop
  /// knows which span to replace. Null when the previous command in this
  /// buffer was not a yank.
  ///
  /// Buffer-local by construction even though the [KillRing] itself is global:
  /// this is a pair of OFFSETS INTO THIS TEXT. Yanking in one buffer and
  /// yank-popping in another would otherwise replace whatever sat at those
  /// offsets there.
  List<int>? lastYankRange;

  /// This buffer's undo/redo history.
  ///
  /// A [_Snapshot] is `(text, caret)` with NO buffer identity attached — the
  /// snapshot itself cannot say which buffer it belongs to. That is exactly
  /// why these used to be discarded on every buffer switch instead of moving
  /// here: a mis-attributed snapshot replayed against the WRONG buffer's text
  /// does not throw, it silently REPLACES that buffer's text with content
  /// that has nothing to do with it. Discarding on switch made a
  /// mis-attribution merely invisible (the record was gone before it could
  /// be replayed wrong); keeping these buffer-local makes correctness depend
  /// on every push/pop going through code that reads from and writes back to
  /// the SAME [Buffer] object — see [EmacsBuffer.current] and the `_undo` /
  /// `_redo` accessors that delegate to it.
  final List<_Snapshot> undo = <_Snapshot>[];
  final List<_Snapshot> redo = <_Snapshot>[];

  /// The buffer's major mode (Emacs `major-mode`).
  ///
  /// Deliberately typed [Object?], not a kit-declared enum: which modes exist
  /// (org / dired / shell / a buffer-menu listing, and what each one *means*)
  /// is application vocabulary, and `desktop_kit` is shared UI components
  /// consumed by more than one host app — the kit cannot import an enum that
  /// lives in one of its consumers, and hard-coding its own competing enum
  /// would just be a second guess at the same domain. The kit stores whatever
  /// the host puts here and never inspects it; see [EmacsBuffer.modeForBuffer]
  /// / [EmacsBuffer.setModeForBuffer].
  Object? mode;

  /// Emacs `default-directory`: the directory filesystem operations local to
  /// THIS buffer resolve against (a dired listing's own directory, the
  /// starting point for a relative open). Null until a host sets it — the
  /// model derives no default (the visited file's parent vs. the process cwd
  /// is host policy, not model policy).
  String? defaultDirectory;

  /// The absolute path of the file THIS buffer visits (Emacs
  /// `buffer-file-name`), or null when it backs no file — `*scratch*`, a
  /// shell buffer, a dired listing.
  String? visitedFile;

  /// Whether [text] has changed since the buffer was last associated with
  /// saved content (Emacs `buffer-modified-p`). Starts false. [EmacsBuffer]
  /// sets this on every write to the CURRENT buffer's [text] (see the
  /// private `_text` setter); a host clears it after a successful save via
  /// [EmacsBuffer.setModifiedForBuffer].
  bool modified = false;

  /// Every match of the last completed search run while THIS buffer was
  /// current, ascending — OFFSETS INTO [text]. Buffer-local: a search's hits
  /// are computed against one buffer's text, so painting them against
  /// another buffer (an inactive split window, say) highlights unrelated
  /// characters purely by where the two texts' lengths happen to line up —
  /// the search twin of the mark-bleeding bug [mark] was moved here to fix.
  List<SearchHit> searchHits = const <SearchHit>[];

  /// Index into [searchHits] of the match at/near point, or -1 when there is
  /// none.
  int searchIndex = -1;

  /// This buffer's active region — ITS mark paired with ITS caret — or null
  /// when no mark is set here.
  ///
  /// Lives on the buffer because both operands do. Pairing one buffer's mark
  /// with another's caret yields a span of offsets that means nothing in
  /// either text, and it renders as a plausible selection rather than raising
  /// anything — the "a selection appeared in two buffers at the same offsets"
  /// report this refactor started from. With both operands on one object,
  /// that pairing cannot be written by accident.
  Region? get region => mark.region(caret);
}

/// One undo/redo snapshot: the full text plus the caret position at that
/// point in time.
class _Snapshot {
  const _Snapshot(this.text, this.caret);
  final String text;
  final int caret;
}

/// A pure (non-Flutter) Emacs-style buffer: text + caret + kill ring + mark
/// + undo history, driven entirely through [insert]/[backspace]/[execute].
class EmacsBuffer {
  EmacsBuffer({String text = '', int caret = 0}) {
    _killRing = KillRing();
    // The selection must be a live object before anything reads _text/_caret —
    // they are views onto [current], not fields.
    final Buffer scratch =
        Buffer(_scratchBufferName, text, caret.clamp(0, text.length));
    _buffers[scratch.name] = scratch;
    _current = scratch;
    final Buffer shell = Buffer('*shell*', '', 0);
    _buffers[shell.name] = shell;
  }

  /// The name a fresh model's initial buffer carries.
  static const String _scratchBufferName = '*scratch*';

  /// Intent ids that [execute] acknowledges but does NOT act on in the buffer —
  /// it sets [status] only, because their real effect lives outside a text
  /// buffer (file I/O, buffer switching, a help browser).
  /// Every OTHER id [execute] handles mutates text / caret / mark / kill-ring.
  /// Exposed so a host UI can honestly distinguish "executes" from "report-only".
  static const Set<String> reportOnlyIntents = <String>{
    'save',
    'openFile',
    'writeFile',
    'help',
    'describeBindings',
    'whereIs',
    'aproposCommand',
    'babelExecute',
    'splitWindowBelow',
    'splitWindowRight',
    'deleteWindow',
    'deleteOtherWindows',
    'otherWindow',
  };

  /// Intents a numeric prefix argument ([pendingArg]) repeats — motions and
  /// kills, as in Emacs. Every other command merely *consumes* the argument.
  static const Set<String> _repeatableIntents = <String>{
    'moveLineStart',
    'moveLineEnd',
    'moveForwardChar',
    'moveBackwardChar',
    'moveNextLine',
    'movePreviousLine',
    'moveForwardWord',
    'moveBackwardWord',
    'moveBufferStart',
    'moveBufferEnd',
    'killLine',
    'killWholeLine',
    'deleteChar',
    'deleteWordForward',
    'deleteWordBackward',
    'yank',
    'newline',
    'insertTab',
    'openLine',
    'transposeChars',
    'transposeWords',
    'transposeLines',
    'upcaseWord',
    'downcaseWord',
    'capitalizeWord',
    'scrollUp',
    'scrollDown',
    'nextBuffer',
    'previousBuffer',
  };

  /// Macro bookkeeping commands — never recorded *into* a macro.
  static const Set<String> _macroMetaIntents = <String>{
    'startMacro',
    'endMacro',
    'callMacro',
  };

  /// Page size for scrollUp / scrollDown, in lines. The widget owns the real
  /// viewport; here a "page" is only a caret move.
  static const int _pageLines = 20;

  /// Maximum snapshots retained per buffer, per stack ([Buffer.undo] /
  /// [Buffer.redo]).
  ///
  /// Undo/redo used to be discarded wholesale on every buffer switch (see
  /// the removed clear in [_resetSessionStateOnSwitch]), which hid unbounded
  /// growth: a long editing session never accumulated more than one
  /// switch's worth of history because everything was thrown away well
  /// before size became visible. Now that a stack lives for the whole life
  /// of its buffer, nothing else bounds it — each [_Snapshot] holds a FULL
  /// COPY of the buffer's text, so an uncapped stack in a long-lived buffer
  /// is unbounded memory, not just an unbounded list length. 200 is a
  /// generous depth for interactive undo (Emacs users rarely walk back more
  /// than a few dozen steps in practice) while keeping the worst case
  /// bounded to `200 × (buffer size)` per stack, per buffer.
  static const int _maxUndoDepth = 200;

  /// The current buffer's live text, caret, mark, yank range and search hits.
  ///
  /// These were plain fields; they are now accessors of the SAME names
  /// delegating to [current], so every in-file reference — including
  /// `_text += x`, `_caret++` and all 28 `_mark.…` calls — compiles and
  /// behaves unchanged while the [Buffer] becomes the single source of truth.
  String get _text => current.text;

  /// Every write marks the CURRENT buffer [Buffer.modified] — see
  /// [Buffer.modified]. This is the one choke point essentially every
  /// text-mutating method in this file already goes through (`insert`,
  /// `backspace`, kill/yank, undo/redo, the EditOps splices, …), so the flag
  /// tracks them all without a second edit at each call site.
  set _text(String value) {
    current.text = value;
    current.modified = true;
  }

  int get _caret => current.caret;
  set _caret(int value) => current.caret = value;

  /// Buffer-local since the mark migration: see [Buffer.mark].
  MarkState get _mark => current.mark;

  /// Buffer-local since the mark migration: see [Buffer.lastYankRange].
  List<int>? get _lastYankRange => current.lastYankRange;
  set _lastYankRange(List<int>? value) => current.lastYankRange = value;

  /// Buffer-local since the search migration: see [Buffer.searchHits].
  List<SearchHit> get _searchHits => current.searchHits;
  set _searchHits(List<SearchHit> value) => current.searchHits = value;

  /// Buffer-local since the search migration: see [Buffer.searchIndex].
  int get _searchIndex => current.searchIndex;
  set _searchIndex(int value) => current.searchIndex = value;

  late final KillRing _killRing;

  /// Buffer-local since the undo migration: see [Buffer.undo] / [Buffer.redo].
  /// No setters — like [_mark], these are mutated in place (`.add`, `.clear`,
  /// `.removeLast`) rather than reassigned as a whole.
  List<_Snapshot> get _undo => current.undo;
  List<_Snapshot> get _redo => current.redo;

  /// Optional pluggable backend for a SUBSET of intents — see
  /// [EditorBackend]. Null (the default) means [executeAsync] behaves
  /// EXACTLY like [execute] for every intent; installing one only changes
  /// behaviour for the ids its [EditorBackend.supports] answers true for.
  /// [execute] itself never reads this field — it is, and stays, the
  /// unconditional Dart-native dispatch for every caller that never calls
  /// [executeAsync].
  EditorBackend? editorBackend;

  /// A stable identity for the CURRENT buffer, for an [EditorBackend] to key
  /// a persistent per-buffer resource on (a subprocess, say) — see
  /// [EditorBackendRequest.bufferId]. [identityHashCode], not [Buffer.name]:
  /// a rename must not read as a buffer switch to a backend holding a
  /// resource keyed on the buffer's identity.
  Object get backendBufferId => identityHashCode(current);

  /// The token most recently handed back by [editorBackend] as
  /// [EditorBackendResult.thisCommand], or empty. Threaded into the NEXT
  /// backend call as [EditorBackendRequest.lastCommand] — see
  /// [executeAsync]'s doc comment.
  String _lastBackendCommand = '';

  final Registers _registers = Registers();
  final MacroRecorder _macros = MacroRecorder();

  /// Nesting depth of [execute], so [insert] records a `self-insert:` macro
  /// step only for *typed* text — never for text an already-recorded intent
  /// (`newline`, `insertTab`) inserts on its own.
  int _inExecute = 0;

  /// True while [_callMacro] re-dispatches recorded steps, so a replay never
  /// re-records itself.
  bool _replaying = false;

  int? _pendingArg;

  _PromptKind? _promptKind;
  String _promptLabel = '';
  String _promptInput = '';

  /// Caret position within [_promptInput] (a code-unit index, `0.._promptInput
  /// .length`). The minibuffer's own line-editing verbs — C-a/C-e/C-f/C-b (move)
  /// and C-k/C-d (kill/delete) — act at this offset; plain typing and Backspace
  /// keep it at the end so nothing about the append behaviour changes.
  int _promptCaret = 0;

  /// Undo history scoped to the ACTIVE prompt's text. Pushed by every
  /// prompt-editing verb ([promptChar], [promptBackspace], [promptKillLine],
  /// [promptDeleteChar], [promptYank]) and popped by [promptUndo] (C-/).
  /// Reuses [_Snapshot] purely for its `(text, caret)` shape — it is a
  /// SEPARATE stack from the buffer's own [Buffer.undo], so undoing in the
  /// minibuffer can never reach past it and undo a buffer edit. Cleared in
  /// [_openPrompt] and [_clearPrompt] so a new prompt never inherits the
  /// previous one's undo history.
  final List<_Snapshot> _promptUndo = <_Snapshot>[];

  /// Where the caret sat when the current isearch started — C-g restores it.
  int _preSearchCaret = 0;

  /// The `from` string of an in-progress query-replace, carried between its
  /// two prompt legs.
  String _queryReplaceFrom = '';

  /// True while the pending query-replace is a *regexp* replace (C-M-%), so the
  /// `with` leg starts a regexp-driven [QueryReplaceSession].
  bool _queryReplaceRegex = false;

  /// The live interactive query-replace walk (y/n/!/q), or null when none is in
  /// progress. Non-null exactly while [queryReplacing].
  QueryReplaceSession? _qrSession;

  /// The from/with display strings for the current walk's status line.
  String _qrFrom = '';
  String _qrWith = '';

  /// The buffer text + caret captured when the walk began — restored as the
  /// single undo step the whole walk collapses to.
  String _qrOrigText = '';
  int _qrOrigCaret = 0;

  /// The last accepted search string — what `occur` reports on.
  String _lastSearch = '';

  /// The most recently killed rectangle, for yankRectangle.
  List<String> _rectangle = const <String>[];

  /// Where the caret sat when swiper started — C-g restores it.
  int _preSwiperCaret = 0;

  /// The live swiper filter/highlight result, or null when not swiping.
  SwiperResult? _swiperResult;

  /// Index into `_swiperResult!.lines` of the currently-previewed candidate,
  /// or -1 when there are no candidates.
  int _swiperSelected = -1;

  /// The candidate-list provider for the active prompt's TAB-completion, or
  /// null when the active prompt (if any) does not offer completion. Set by
  /// the host via [setCompletionProvider] right after opening a prompt that
  /// wants it (M-x, switch-buffer); cleared whenever the prompt closes.
  List<String> Function(String input)? _completionProvider;

  /// The current completion candidates for [_promptInput] — the expandable
  /// strip the host renders between the buffer and the minibuffer.
  List<String> _completionCandidates = const <String>[];

  /// Index into [_completionCandidates] of the highlighted row, or -1 when
  /// none is highlighted (RET then executes the typed text as-is).
  int _completionSelected = -1;

  /// The command id an `executeCommand` prompt just accepted, consumed once
  /// by the host via [takePendingCommand].
  String? _pendingCommand;

  /// The pattern an `occur` intent just accepted (or reused from
  /// [_lastSearch]), consumed once by the host via [takePendingOccurQuery] —
  /// the host owns the `*Occur*` dialog since the model has no widget.
  String? _pendingOccurQuery;

  /// The buffer list, INDEXED by name. The index is a lookup convenience; the
  /// buffers themselves are the truth, and each one carries its own
  /// [Buffer.name] — see that field for why the direction matters.
  ///
  /// ITERATION ORDER doubles as buffer-list order: [bufferNames] and
  /// [bufferSnapshots] both derive from it directly (Dart's [Map] preserves
  /// insertion order). It starts as creation order; [buryBuffer] is the one
  /// operation that deliberately disturbs it, by removing and re-inserting an
  /// entry to move it to the end.
  final Map<String, Buffer> _buffers = <String, Buffer>{};

  /// The selected buffer — a REFERENCE, not a name.
  ///
  /// This is the last half of the amendment the refactor plan made to its own
  /// decision 3 ("`current` must be a `Buffer` reference, not a name"). While
  /// this was a `String _currentBuffer`, the name was the truth and [current]
  /// was derived from it by map lookup; now the object is the truth and
  /// [currentBuffer] is derived from it. Everything that used to be able to go
  /// stale against a rename — the selection itself, and every window pointing
  /// at a buffer — follows the object instead of a key that expires.
  ///
  /// `late` rather than nullable: the constructor assigns it before anything
  /// can read it, and a nullable selection would push a `!` into [current],
  /// the single hottest accessor in this file.
  late Buffer _current;

  /// The selected [Buffer]. Every `_text` / `_caret` / `_mark` read in this
  /// file goes through here, so this is the hot path — deliberately a plain
  /// field read with no lookup and no indirection.
  Buffer get current => _current;

  /// Called immediately after the selection moves to a different [Buffer], so
  /// a host that owns a WINDOW model can repoint its selected window at the
  /// same object in the same step.
  ///
  /// This is what makes "the selected window's buffer" and "the current
  /// buffer" one fact rather than two that must be reconciled. Before it, a
  /// `C-x b` moved the model's selection and left the selected window's
  /// pointer stale until the next `C-x o` happened to write it back — and
  /// anything reading that pointer in between got the previous buffer.
  /// `WindowTree` clones it on `C-x 2`/`C-x 3` and rebuilds from it on
  /// `C-x 1`, so splitting after a switch produced two windows showing
  /// DIFFERENT buffers where Emacs shows one buffer in both.
  ///
  /// Deliberately a plain callback rather than a [WindowTree] reference: the
  /// window model stays out of the buffer model (and out of every headless
  /// test), and the model still cannot be left disagreeing with it.
  void Function(Buffer selected)? onSelectionChanged;

  /// Repoint the selection at [buffer] — the seam a WINDOW uses to say "I am
  /// the selected window, and this is the buffer I hold".
  ///
  /// The inverse direction of [onSelectionChanged], and the reason `current`
  /// can be described as derived from the selected window: focus moves, the
  /// window reports what it holds, and the model follows. Routed through
  /// [switchToBuffer] rather than assigning [_current] directly so a
  /// window-driven selection change gets exactly the same session-state
  /// handling (kill-sequence break, prompt clear, caret clamp) as a `C-x b`.
  ///
  /// No-op when [buffer] is already selected. Asserts [buffer] is live — a
  /// window holding a killed buffer must be repaired by its host (see
  /// [isLive]), never silently made current.
  void selectBuffer(Buffer buffer) {
    if (identical(buffer, _current)) return;
    assert(
      isLive(buffer),
      'selectBuffer: $buffer is not a live buffer in this model. A window '
      'holding a killed buffer must be repointed by its host (see isLive) '
      'rather than selected.',
    );
    if (!isLive(buffer)) return;
    switchToBuffer(buffer.name);
  }

  /// Whether [buffer] is still a live buffer of this model — i.e. the index
  /// still resolves its own name back to this very object.
  ///
  /// IDENTITY, not name equality, and that is the whole point. Killing a
  /// buffer and then creating a new one with the same name must leave a window
  /// still holding the OLD object stranded, not silently re-attached to an
  /// unrelated buffer that merely inherited the name. A rename, conversely,
  /// keeps the object in the index under its new key, so it stays live —
  /// which is exactly backwards from what a name-keyed check reports.
  bool isLive(Buffer buffer) => identical(_buffers[buffer.name], buffer);

  /// The [Buffer] named [name], or null when no such buffer exists. The live
  /// object — a window displaying it reads through this and sees edits as they
  /// happen, rather than the last snapshot taken at switch time.
  Buffer? bufferNamed(String name) => _buffers[name];

  String status = '';

  String get text => _text;

  int get caret => _caret;
  set caret(int v) {
    _caret = v.clamp(0, _text.length);
  }

  // ---- the name-addressed WINDOW seam (deprecated; removal 2026-10-31) ----
  //
  // Phases 1 and 4-7 added these so a WINDOW could ask about the buffer it
  // displays without holding it: the window had only a NAME, so every
  // window-scoped read had to be routed through a name lookup here. Phase 8
  // gives the window the [Buffer] itself ([WindowLeaf.buffer]), which makes
  // every one of them a redundant indirection through a key that can expire —
  // and re-introducing one is how a window-scoped read goes back to being
  // addressed by something that goes stale.
  //
  // The REMOVAL DATE is deliberate and is not conditioned on anything. This
  // repo already carries the counter-example: `PrefixDispatcher` is marked
  // "removed once voicelab migrates in step 3" and is still here, because a
  // deprecation whose trigger is somebody else's migration never fires. See
  // `docs/design/window-holds-buffer.org` for the migration table.
  //
  // Note these are SILENT inside desktop_kit (this package does not enable
  // `deprecated_member_use_from_same_package`) and reported as `info` — hence
  // a `flutter analyze` failure — in every CONSUMING package. That asymmetry
  // is why they still have in-package callers below while textloom has none.

  /// The text of the buffer named [name], or null when no such buffer exists.
  @Deprecated(
    'Use bufferNamed(name)?.text — or, in a window, leaf.buffer.text. '
    'A window holds the Buffer object since the window-holds-buffer phase, so '
    'addressing its own buffer by name is an indirection through a key that '
    'expires on rename. Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  String? textForBuffer(String name) => _buffers[name]?.text;

  /// The caret offset of the buffer named [name], or null when no such buffer
  /// exists.
  @Deprecated(
    'Use bufferNamed(name)?.caret — or, in a window, leaf.buffer.caret. '
    'Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  int? caretForBuffer(String name) => _buffers[name]?.caret;

  /// The [MarkState] of the buffer named [name], or null when no such buffer
  /// exists.
  @Deprecated(
    'Use bufferNamed(name)?.mark — or, in a window, leaf.buffer.mark. '
    'Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  MarkState? markForBuffer(String name) => _buffers[name]?.mark;

  /// The active region of the buffer named [name] — its mark paired with ITS
  /// caret — or null when there is no such buffer, or no mark set in it.
  @Deprecated(
    'Use bufferNamed(name)?.region — or, in a window, leaf.buffer.region, '
    'which pairs the mark and caret of ONE buffer by construction. '
    'Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  Region? regionForBuffer(String name) => _buffers[name]?.region;

  /// The major mode of the buffer named [name], or null when there is no
  /// such buffer or none was ever set. See [Buffer.mode] for why this is
  /// opaque to the kit — the host casts it back to its own mode type.
  Object? modeForBuffer(String name) => _buffers[name]?.mode;

  /// Assigns [mode] to the buffer named [name]. No-op when there is no such
  /// buffer. This is the seam a host uses INSTEAD OF keeping its own
  /// buffer-name-keyed mode map: a second map is a second source of truth,
  /// and the two silently disagreeing is exactly what makes a window paint
  /// org content in plain text (or the reverse) — see [Buffer.mode].
  void setModeForBuffer(String name, Object? mode) {
    _buffers[name]?.mode = mode;
  }

  /// The directory the buffer named [name] resolves relative filesystem
  /// operations against, or null when there is no such buffer or none was
  /// ever set. See [Buffer.defaultDirectory].
  String? defaultDirectoryForBuffer(String name) =>
      _buffers[name]?.defaultDirectory;

  /// Sets the buffer named [name]'s default directory. No-op when there is
  /// no such buffer.
  void setDefaultDirectoryForBuffer(String name, String? directory) {
    _buffers[name]?.defaultDirectory = directory;
  }

  /// The absolute path the buffer named [name] visits, or null when there is
  /// no such buffer or it backs no file. See [Buffer.visitedFile].
  String? visitedFileForBuffer(String name) => _buffers[name]?.visitedFile;

  /// Sets the buffer named [name]'s visited file path. No-op when there is
  /// no such buffer.
  void setVisitedFileForBuffer(String name, String? path) {
    _buffers[name]?.visitedFile = path;
  }

  /// Whether the buffer named [name] has unsaved changes, or null when there
  /// is no such buffer. See [Buffer.modified].
  bool? modifiedForBuffer(String name) => _buffers[name]?.modified;

  /// Sets the buffer named [name]'s modified flag — a host calls this with
  /// `false` after a successful save. No-op when there is no such buffer.
  void setModifiedForBuffer(String name, bool value) {
    _buffers[name]?.modified = value;
  }

  /// Every match of the last completed search run while the buffer named
  /// [name] was current, ascending, or empty when there is no such buffer or
  /// nothing was ever searched there.
  @Deprecated(
    'Use bufferNamed(name)?.searchHits — or, in a window, '
    'leaf.buffer.searchHits. '
    'Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  List<SearchHit> searchHitsForBuffer(String name) {
    final Buffer? b = _buffers[name];
    return b == null
        ? const <SearchHit>[]
        : List<SearchHit>.unmodifiable(b.searchHits);
  }

  /// Index into the named buffer's search hits, of the match at/near that
  /// buffer's point — or -1 when there is no such buffer, or no current match.
  @Deprecated(
    'Use bufferNamed(name)?.searchIndex — or, in a window, '
    'leaf.buffer.searchIndex. '
    'Will be REMOVED on 2026-10-31 (desktop_kit 0.4.0).',
  )
  int searchIndexForBuffer(String name) => _buffers[name]?.searchIndex ?? -1;

  KillRing get killRing => _killRing;

  /// The CURRENT buffer's mark. Buffer-local — see [markForBuffer] for any
  /// other buffer.
  MarkState get mark => _mark;

  Region? get region => _mark.region(_caret);

  String? get regionText {
    final r = region;
    if (r == null) return null;
    return _text.substring(r.start, r.end);
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Single-char named string storage (C-x r s / C-x r i).
  Registers get registers => _registers;

  /// Keyboard-macro recorder (C-x ( / C-x ) / C-x e).
  MacroRecorder get macros => _macros;

  /// The pending numeric prefix argument (C-u), or null when none. Cycles
  /// 4, 16, 64 … via [universalArgument]; the next [execute] consumes it.
  int? get pendingArg => _pendingArg;

  /// Clears [pendingArg] without dispatching anything, for a host-
  /// intercepted intent (e.g. `M-x shell`, which never reaches [execute])
  /// that still needs to consume a pending `C-u` itself.
  void clearPendingArg() {
    _pendingArg = null;
  }

  /// The minibuffer text a host should render (label + what has been typed),
  /// or null when no prompt is active.
  String? get prompt =>
      _promptKind == null ? null : '$_promptLabel$_promptInput';

  /// Caret offset within the typed minibuffer input (0-based code-unit index),
  /// or 0 when no prompt is open. Exposed so the line-editing verbs
  /// (C-a/C-e/C-f/C-b/C-k/C-d) are observable/testable — the model owns the
  /// caret; a host may paint it but is not required to.
  int get promptCaret => _promptKind == null ? 0 : _promptCaret;

  /// [promptCaret] as an index into the concatenated [prompt] string (label +
  /// input) — where a renderer should paint the minibuffer's caret block.
  int get promptCaretInPrompt =>
      _promptKind == null ? 0 : _promptLabel.length + _promptCaret;

  /// Whether the active prompt is an incremental search (literal or regexp), so
  /// a host can render [searchHits] as live match highlights.
  bool get isearching =>
      _promptKind == _PromptKind.isearchForward ||
      _promptKind == _PromptKind.isearchBackward ||
      _promptKind == _PromptKind.isearchForwardRegexp ||
      _promptKind == _PromptKind.isearchBackwardRegexp;

  /// True when the active isearch is a regexp search (C-M-s / C-M-r).
  bool get _isearchRegex =>
      _promptKind == _PromptKind.isearchForwardRegexp ||
      _promptKind == _PromptKind.isearchBackwardRegexp;

  /// True when the active isearch scans backward (C-r / C-M-r).
  bool get _isearchBackward =>
      _promptKind == _PromptKind.isearchBackward ||
      _promptKind == _PromptKind.isearchBackwardRegexp;

  /// Every match of the current isearch string, ascending. Empty when not
  /// searching.
  List<SearchHit> get searchHits => List<SearchHit>.unmodifiable(_searchHits);

  /// Index into [searchHits] of the match the caret is on, or -1 when there
  /// is none.
  int get searchIndex => _searchIndex;

  /// True while an interactive query-replace walk is awaiting a y/n/!/q
  /// decision. The host shows the [queryReplacePrompt] bar and routes those
  /// keys to [queryReplaceRespond] instead of the buffer.
  bool get queryReplacing => _qrSession != null;

  /// The query-replace prompt line to render during the walk, or null when no
  /// walk is in progress.
  String? get queryReplacePrompt => _qrSession == null
      ? null
      : 'Query replacing $_qrFrom with $_qrWith: (y)es (n)ext (!)all (q)uit';

  /// True while the swiper live filtered line search is active — the host
  /// shows the [swiperCandidates] panel and routes ArrowUp/Down (and
  /// C-n/C-p) to [swiperNext]/[swiperPrevious].
  bool get swiping => _promptKind == _PromptKind.swiper;

  /// The current swiper candidate lines (one per matching buffer line), or
  /// empty when not swiping. See `swiper.dart` for the matching semantics.
  List<SwiperLine> get swiperCandidates => swiping
      ? (_swiperResult?.lines ?? const <SwiperLine>[])
      : const <SwiperLine>[];

  /// Index into [swiperCandidates] of the previewed candidate, or -1 when
  /// there are none (or not swiping).
  int get swiperSelected => swiping ? _swiperSelected : -1;

  /// True while the active prompt offers TAB-completion candidates (see
  /// [setCompletionProvider]) — the host shows [completionCandidates] as the
  /// expandable strip and routes TAB / ArrowUp / ArrowDown to [promptTab] /
  /// [completionSelectPrevious] / [completionSelectNext].
  bool get completing => _completionProvider != null;

  /// The current completion candidates for the active prompt's text, or
  /// empty when [completing] is false.
  List<String> get completionCandidates =>
      List<String>.unmodifiable(_completionCandidates);

  /// Index into [completionCandidates] of the highlighted row, or -1 when
  /// none is highlighted.
  int get completionSelected => _completionSelected;

  /// Install [provider] as the active prompt's completion source and
  /// immediately compute its first candidate list. [provider] takes the
  /// prompt's current text and returns the already-filtered candidate
  /// strings (e.g. registry ids starting with the input, or directory
  /// entries under it) — [EmacsBuffer] never second-guesses the filtering.
  /// No-op when no prompt is open.
  void setCompletionProvider(List<String> Function(String input) provider) {
    if (_promptKind == null) return;
    _completionProvider = provider;
    _recomputeCompletion();
  }

  /// Every buffer's name, in BUFFER-LIST order — creation order, except that
  /// [buryBuffer] moves a name to the end. Always includes [currentBuffer].
  List<String> get bufferNames => List<String>.unmodifiable(_buffers.keys);

  /// The name of the buffer whose text is currently in [text].
  ///
  /// DERIVED from the selected [Buffer], not stored beside it. A stored name
  /// is a second copy of the selection that can disagree with the first, and
  /// under `renameBuffer` it did.
  String get currentBuffer => _current.name;

  void _pushUndo() {
    _pushSnapshot(_undo, _Snapshot(_text, _caret));
    _redo.clear();
  }

  /// Append [snap] to [stack] and trim from the OLDEST end (index 0) if that
  /// pushes it past [_maxUndoDepth]. Every direct `.add` onto [_undo] /
  /// [_redo] — [_pushUndo], [_undoOp]'s redo push, [_redoOp]'s undo push, and
  /// the collapsed query-replace step — goes through this so the cap holds
  /// regardless of which path pushed the snapshot.
  void _pushSnapshot(List<_Snapshot> stack, _Snapshot snap) {
    stack.add(snap);
    while (stack.length > _maxUndoDepth) {
      stack.removeAt(0);
    }
  }

  void _replaceText(String newText, {required int newCaret}) {
    _text = newText;
    _caret = newCaret.clamp(0, _text.length);
  }

  /// Overwrite the ENTIRE buffer with [newText] (dired mark/flag/refresh —
  /// the buffer's own commands rewriting its listing, not user typing),
  /// optionally moving the caret. Undo-recorded, so a mis-mark is C-/-able.
  void overwriteText(String newText, {int? caret}) {
    _pushUndo();
    _killRing.breakKillSequence();
    _replaceText(newText, newCaret: caret ?? _caret.clamp(0, newText.length));
  }

  /// Establish [newText] as this buffer's BASELINE content — a file load, not
  /// an edit. Discards undo/redo history and clears [Buffer.modified].
  ///
  /// Use this, never [overwriteText], when text arrives from disk into a
  /// buffer. [overwriteText] records undo, so loading a file into a fresh
  /// buffer left exactly one undoable state: THE EMPTY BUFFER. A single undo
  /// after opening a file therefore blanked it, and since the redo stack is
  /// dropped the moment anything else is typed, the content could be
  /// unrecoverable — from one keystroke, on a file the user had merely opened.
  ///
  /// That mirrors Emacs, where `find-file` leaves `buffer-undo-list` empty and
  /// the buffer unmodified: you cannot undo your way to before a file existed
  /// in its buffer, because loading it was never an edit.
  ///
  /// Deliberately NOT for `revert-buffer`, which is undo-recorded on purpose so
  /// an accidental revert stays recoverable, nor for syncing the model after a
  /// save, which must preserve the history of edits made before it.
  void loadText(String newText, {int? caret}) {
    _killRing.breakKillSequence();
    _replaceText(newText, newCaret: caret ?? _caret.clamp(0, newText.length));
    current.undo.clear();
    current.redo.clear();
    current.modified = false;
  }

  /// Insert [s] at the caret, advancing the caret past it. Records undo.
  ///
  /// When a keyboard macro is being recorded and this is *typed* text (i.e.
  /// not an insertion an intent is already doing on its own), the keystroke is
  /// recorded as a `self-insert:` step.
  void insert(String s) {
    if (_inExecute == 0) _recordStep('self-insert:$s');
    _insertRaw(s);
  }

  /// [insert] without the macro bookkeeping — the internal insertion path.
  void _insertRaw(String s) {
    _pushUndo();
    _text = _text.substring(0, _caret) + s + _text.substring(_caret);
    _mark.adjustForEdit(_caret, s.length);
    _caret += s.length;
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Inserted';
  }

  /// Apply a pure org-structure edit (see `org_structure.dart`) to the
  /// buffer: runs [op] over the current text/caret, pushes undo, and
  /// replaces text/caret with its result. Kept generic here (no case-by-case
  /// switch) so the model does not need to know which structural op ran —
  /// the editor widget picks [op] (`insertHeadingAfter`, `promoteHeading`,
  /// `demoteHeading`, `moveSubtreeUp`, `moveSubtreeDown`, `todoCycle`) and
  /// sets [status] afterward. A no-op [op] (text and caret both unchanged)
  /// still breaks the kill sequence but does not push a redundant undo step.
  void applyOrgEdit(OrgEdit Function(String text, int caret) op) {
    final OrgEdit edit = op(_text, _caret);
    if (edit.text == _text && edit.caret == _caret) return;
    _pushUndo();
    _text = edit.text;
    _caret = edit.caret.clamp(0, _text.length);
    _lastYankRange = null;
    _killRing.breakKillSequence();
  }

  /// Replace the [deleteBefore] characters immediately before the caret with
  /// [insertText], as ONE edit (one undo step, one mark adjustment).
  ///
  /// This is the general caret-adjacent splice primitive an incremental-input
  /// engine needs: e.g. the kit's `RomajiInputBuffer.feed` returns exactly
  /// this shape per keystroke (delete the previously-visible pending raw
  /// romaji, insert the newly-finalised kana plus the new pending tail).
  /// [insert]/[backspace] cover the two single-character cases; this covers
  /// "replace N characters immediately before point with M new ones."
  ///
  /// [coalesce] merges this edit into the current top-of-undo-stack edit
  /// instead of pushing a new snapshot — for a multi-keystroke run (e.g. a
  /// single composed word) that should undo as ONE step. It is only correct
  /// when the caller guarantees no OTHER mutation has intervened since the
  /// run's first edit (which does push a snapshot) — i.e. the caller owns an
  /// invariant like "the pending run is always flushed before any other
  /// command can dispatch." If that invariant is ever violated, coalescing
  /// silently absorbs an unrelated edit into the run's undo step.
  ///
  /// [macroStep], when non-null, records a keyboard-macro step (mirroring
  /// [insert]'s own recording) — pass null for the intermediate states of a
  /// composition and record one summary step when the run commits instead.
  ///
  /// No-op (no undo push) when there is nothing to delete and nothing to
  /// insert.
  void replaceBeforeCaret(
    int deleteBefore,
    String insertText, {
    bool coalesce = false,
    String? macroStep,
  }) {
    final int start = (_caret - deleteBefore).clamp(0, _text.length);
    if (start == _caret && insertText.isEmpty) return;
    if (macroStep != null && _inExecute == 0) _recordStep(macroStep);
    if (coalesce && _undo.isNotEmpty) {
      _redo.clear();
    } else {
      _pushUndo();
    }
    _text = _text.substring(0, start) + insertText + _text.substring(_caret);
    _mark.adjustForEdit(start, insertText.length - (_caret - start));
    _caret = start + insertText.length;
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Inserted';
  }

  /// Record a `self-insert:` keyboard-macro step for [s] without touching the
  /// buffer — the escape hatch a host-driven insert (e.g. a committed
  /// incremental-input run, whose intermediate keystrokes recorded nothing)
  /// uses to make macro replay reproduce the same net text. No-op while a
  /// macro replay is already in progress (mirrors [insert]'s own guard).
  void recordSelfInsert(String s) {
    if (_inExecute == 0) _recordStep('self-insert:$s');
  }

  /// Delete the character immediately before the caret. Records undo.
  void backspace() {
    if (_caret <= 0) {
      status = 'Beginning of buffer';
      return;
    }
    _pushUndo();
    _text = _text.substring(0, _caret - 1) + _text.substring(_caret);
    _mark.adjustForEdit(_caret - 1, -1);
    _caret -= 1;
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Backspace';
  }

  /// Run the command bound to [intentId], returning false for ids this model
  /// does not handle.
  ///
  /// Wraps the dispatch with the two cross-cutting Emacs behaviours: a pending
  /// numeric prefix argument (repeating motions/kills, consumed by everything
  /// else) and keyboard-macro recording.
  bool execute(String intentId) {
    _inExecute++;
    try {
      if (!_macroMetaIntents.contains(intentId)) _recordStep(intentId);

      // C-u only *sets* the argument — it must not consume it.
      if (intentId == 'universalArgument') {
        universalArgument();
        return true;
      }

      // M-x (execute-extended-command) itself must not consume a pending
      // prefix argument — Emacs relays it to whatever command the user
      // names next (`C-u M-x shell` reaches `shell` with the arg still
      // set), consumed only once that command actually runs. Opening the
      // M-x prompt is therefore exempt from the general clear below.
      if (intentId == 'executeExtendedCommand') {
        return _dispatch(intentId);
      }

      final int? arg = _pendingArg;
      _pendingArg = null;

      if (arg != null && _repeatableIntents.contains(intentId)) {
        var handled = false;
        for (var i = 0; i < arg; i++) {
          if (_dispatch(intentId)) handled = true;
        }
        if (handled) status = '$status (x$arg)';
        return handled;
      }
      return _dispatch(intentId);
    } finally {
      _inExecute--;
    }
  }

  // ============================================================ editor seam
  //
  // [executeAsync] is an ADDITIVE entry point beside [execute], not a
  // replacement for it. [execute] cannot itself await a backend (a widget's
  // synchronous key-event path calls it directly, and the ~80 intents that
  // are not part of any backend's [EditorBackend.supports] must keep working
  // with zero behavioural change) — so this method re-implements execute's
  // own thin wrapper (prefix-argument repeat, keyboard-macro recording) for
  // the async path, and delegates the base case to whichever of TWO places
  // actually knows how to run one command: [editorBackend] when it supports
  // [intentId], [execute] otherwise. See `EmacsBufferEditor`'s own wiring in
  // textloom for how a real widget threads key events through this instead of
  // [execute] for a backend-routed id.
  //
  // WHERE STATE LIVES, AND WHERE IT DOES NOT, FOR A BACKEND-ROUTED EDIT.
  // [Buffer.text]/[Buffer.caret]/[Buffer.mark] are ALWAYS applied here, from
  // whatever the backend returns — this model remains the one source of
  // truth a widget's TextEditingController reads from, exactly as for
  // [execute]. Undo is where it gets interesting, because a backend may keep
  // ITS OWN undo history (textloom's Go backend does, over the real elisp
  // `undo` primitive) that this model cannot see the internals of — so two
  // independent mechanisms exist side by side:
  //
  //   * A backend-routed EDIT (not a motion) still pushes a whole-text
  //     [_Snapshot] onto THIS buffer's [_undo] via [_pushUndo], exactly like
  //     every Dart-native edit. This buffer's undo history is therefore
  //     ALWAYS a complete, gap-free record of every edit regardless of which
  //     engine performed it.
  //   * A backend-routed UNDO tries the backend FIRST. On success, this
  //     model pops [_undo] and pushes [_redo] in the exact same shape
  //     [_undoOp] does — using the CURRENT (pre-undo) text/caret, not the
  //     popped snapshot's content, because the backend (not the popped
  //     snapshot) is authoritative on what the reverted state actually is.
  //     This is what keeps the two stacks aligned: as long as every backend
  //     edit pushes and every backend undo pops, [_undo]/[_redo] describe
  //     the SAME sequence of steps a Dart-only session would have recorded,
  //     so a plain Dart-native `redo` (redo is not in any slice this seam
  //     ships with a backend for) still replays a backend-undone edit
  //     correctly.
  //   * A backend-routed UNDO that FAILS (the backend's own history is
  //     exhausted, or was dropped by a resync — see the backend's own docs
  //     for what forces that) falls back to THIS model's [_undoOp], which
  //     reads [_undo] exactly as it would for an all-Dart session. Given the
  //     push/pop lockstep above, [_undo] is correct to fall back to at
  //     exactly the moment the backend's own history runs out — not before,
  //     not after.
  //
  // THE NAMED FAILURE MODE. A backend's own undo can only revert what IT
  // saw. The moment some edit happens that never went through THIS backend
  // — typing, or any of the ~80 intents this seam does not route — the
  // backend's internal buffer mirror no longer matches this model's [_text],
  // and a backend's honest response to that (textloom's Go backend: a full
  // resync, dropping its OWN undo list) means the backend can no longer
  // undo ACROSS that edit. The [_undo] fallback above is what keeps `undo`
  // working ACROSS such a gap regardless — it is a genuine safety net, not
  // cosmetic — but the backend's own mechanism, which is the reason this
  // seam exists at all, is scoped to an unbroken run of backend-routed
  // commands. Document this at the call site that installs a backend, not
  // just here.
  //
  // Motions push nothing (mirroring [_breakAndMove]) and only ever break the
  // kill sequence.
  Future<bool> executeAsync(String intentId) async {
    final EditorBackend? backend = editorBackend;
    if (backend == null || !backend.supports(intentId)) {
      // Unsupported by any backend: the ENTIRE existing path, unchanged,
      // including its own step recording and prefix-argument handling. Not
      // "equivalent to" execute() — literally execute(), so a caller mixing
      // executeAsync and execute across different intents can never observe
      // a difference for an id no backend claims.
      _lastBackendCommand = '';
      return execute(intentId);
    }

    if (!_macroMetaIntents.contains(intentId)) _recordStep(intentId);
    _inExecute++;
    try {
      final int? arg = _pendingArg;
      _pendingArg = null;
      if (arg != null && _repeatableIntents.contains(intentId)) {
        var handled = false;
        for (var n = 0; n < arg; n++) {
          if (await _dispatchBackendOnce(backend, intentId)) handled = true;
        }
        if (handled) status = '$status (x$arg)';
        return handled;
      }
      return await _dispatchBackendOnce(backend, intentId);
    } finally {
      _inExecute--;
    }
  }

  /// Run ONE backend-routed command (no prefix-argument repeat, no macro
  /// recording — [executeAsync] already handled both). On a `!ok` result
  /// falls back to [_dispatch] directly (NOT [execute], which would record a
  /// second, duplicate macro step for the same keystroke) — see
  /// [executeAsync]'s doc comment for what this buys for `undo`/`yank`
  /// specifically.
  Future<bool> _dispatchBackendOnce(
      EditorBackend backend, String intentId) async {
    final EditorBackendRequest req = EditorBackendRequest(
      bufferId: backendBufferId,
      text: _text,
      point: _caret,
      mark: _mark.mark,
      lastCommand: _lastBackendCommand,
    );
    final EditorBackendResult result = await backend.run(intentId, req);
    if (!result.ok) {
      _lastBackendCommand = '';
      return _dispatch(intentId);
    }

    // Keep DART's OWN kill ring's append-merge bookkeeping sane even though
    // this slice's kill/yank never touch it (see the class-level seam docs):
    // a motion or undo breaks a pending kill sequence exactly like
    // [_breakAndMove] / [_undoOp] do, so a LATER Dart-native kill (outside
    // this backend's five intents) does not wrongly append onto a kill from
    // before an intervening Go-routed motion.
    if (intentId != 'killLine' && intentId != 'yank') {
      _killRing.breakKillSequence();
    }

    if (intentId == 'undo') {
      // Pop/push in lockstep with the backend's OWN successful undo — see
      // executeAsync's doc comment for why this, and not a fresh push, is
      // correct here.
      if (_undo.isNotEmpty) {
        _undo.removeLast();
        _pushSnapshot(_redo, _Snapshot(_text, _caret));
      }
    } else if (result.text != null && result.text != _text) {
      // A backend-routed EDIT: record undo exactly like a Dart-native one.
      _pushUndo();
    }

    // Through the [_text] SETTER, not `current.text =` directly: that setter
    // is the one place that marks [Buffer.modified] (see its doc comment),
    // and a pure motion (moveForwardChar/moveLineStart, whose `result.text`
    // is always null — nothing to write back) must NOT flip that flag, the
    // same as [_breakAndMove] never does.
    if (result.text != null) _text = result.text!;
    if (result.point != null) _caret = result.point!.clamp(0, _text.length);
    if (result.markSet) {
      final int? mv = result.markValue;
      if (mv == null) {
        _mark.clear();
      } else {
        _mark.setMark(mv.clamp(0, _text.length));
      }
    }
    if (intentId == 'yank' && result.point != null) {
      // [req.point] is the caret BEFORE this yank ran (nothing above
      // mutates the request); [_caret] is the caret AFTER, just applied.
      // Set for hygiene/symmetry with a Dart-native yank — [_yankPop] gates
      // on the (Dart-native, backend-independent) kill ring being in the
      // "just yanked" state too, which a backend-routed yank never puts it
      // in, so this alone does not make `yank-pop` follow a backend yank.
      _lastYankRange = <int>[req.point, _caret];
    } else {
      _lastYankRange = null;
    }
    _lastBackendCommand = result.thisCommand;
    status = result.status ?? intentId;
    return true;
  }

  bool _dispatch(String intentId) {
    switch (intentId) {
      // ---- Motions ---------------------------------------------------
      case 'moveLineStart':
        _breakAndMove(TextMotions.lineStart(_text, _caret));
        status = 'Beginning of line';
        return true;
      case 'moveLineEnd':
        _breakAndMove(TextMotions.lineEnd(_text, _caret));
        status = 'End of line';
        return true;
      case 'moveForwardChar':
        _breakAndMove(TextMotions.forwardChar(_text, _caret));
        status = 'Forward char';
        return true;
      case 'moveBackwardChar':
        _breakAndMove(TextMotions.backwardChar(_text, _caret));
        status = 'Backward char';
        return true;
      case 'moveNextLine':
        _breakAndMove(TextMotions.nextLine(_text, _caret));
        status = 'Next line';
        return true;
      case 'movePreviousLine':
        _breakAndMove(TextMotions.previousLine(_text, _caret));
        status = 'Previous line';
        return true;
      case 'moveForwardWord':
        _breakAndMove(TextMotions.forwardWord(_text, _caret));
        status = 'Forward word';
        return true;
      case 'moveBackwardWord':
        _breakAndMove(TextMotions.backwardWord(_text, _caret));
        status = 'Backward word';
        return true;
      case 'moveBufferStart':
        _breakAndMove(0);
        status = 'Beginning of buffer';
        return true;
      case 'moveBufferEnd':
        _breakAndMove(_text.length);
        status = 'End of buffer';
        return true;

      // ---- Mark --------------------------------------------------------
      case 'setMark':
        _killRing.breakKillSequence();
        _mark.setMark(_caret);
        status = 'Mark set';
        return true;
      case 'exchangePointAndMark':
        _killRing.breakKillSequence();
        final m = _mark.exchange(_caret);
        if (m != null) {
          _caret = m;
        }
        status = 'Exchange point and mark';
        return true;
      case 'markWholeBuffer':
        _killRing.breakKillSequence();
        _mark.setMark(_text.length);
        _caret = 0;
        status = 'Mark whole buffer';
        return true;
      case 'markPage':
        _killRing.breakKillSequence();
        _mark.setMark(_text.length);
        _caret = 0;
        status = 'Mark page';
        return true;

      // ---- Kill / yank ---------------------------------------------
      case 'killLine':
        _killLine();
        return true;
      case 'killWholeLine':
        _killWholeLine();
        return true;
      case 'killRegion':
        _killRegion();
        return true;
      case 'copyRegion':
        _copyRegion();
        return true;
      case 'deleteChar':
        _deleteChar();
        return true;
      case 'deleteWordForward':
        _deleteWordForward();
        return true;
      case 'deleteWordBackward':
        _deleteWordBackward();
        return true;
      case 'yank':
        _yank();
        return true;
      case 'yankPop':
        _yankPop();
        return true;

      // ---- Editing ---------------------------------------------------
      case 'openLine':
        _openLine();
        return true;
      case 'transposeChars':
        _transposeChars();
        return true;
      case 'upcaseWord':
        _caseWord(_upper);
        status = 'Upcase word';
        return true;
      case 'downcaseWord':
        _caseWord(_lower);
        status = 'Downcase word';
        return true;
      case 'capitalizeWord':
        _caseWord(_titleCase);
        status = 'Capitalize word';
        return true;
      case 'justOneSpace':
        _justOneSpace();
        return true;
      case 'deleteHorizontalSpace':
        _deleteHorizontalSpace();
        return true;
      case 'undo':
        _undoOp();
        return true;
      case 'redo':
        _redoOp();
        return true;

      // ---- Terminal / whitespace translations (tty control codes) ------
      case 'newline': // C-j (LF) / C-m (CR) / RET
        insert('\n');
        status = 'Newline';
        return true;
      case 'insertTab': // C-i (HT) / TAB
        insert('\t');
        status = 'Inserted tab';
        return true;

      // ---- Search ----------------------------------------------------
      case 'isearchForward':
        _startIsearch(backward: false);
        return true;
      case 'isearchBackward':
        _startIsearch(backward: true);
        return true;
      case 'isearchForwardRegexp':
        _startIsearch(backward: false, regex: true);
        return true;
      case 'isearchBackwardRegexp':
        _startIsearch(backward: true, regex: true);
        return true;
      case 'queryReplace':
        _killRing.breakKillSequence();
        _queryReplaceFrom = '';
        _queryReplaceRegex = false;
        _openPrompt(_PromptKind.queryReplaceFrom, 'Query replace: ');
        return true;
      case 'queryReplaceRegexp':
        _killRing.breakKillSequence();
        _queryReplaceFrom = '';
        _queryReplaceRegex = true;
        _openPrompt(_PromptKind.queryReplaceFrom, 'Query replace regexp: ');
        return true;
      case 'occur':
        // M-x occur always prompts, with the last search string as the
        // implicit default (real Emacs behaviour) — when there IS one
        // already, skip the round-trip through the minibuffer and hand the
        // host a pending query directly.
        _killRing.breakKillSequence();
        if (_lastSearch.isEmpty) {
          _openPrompt(_PromptKind.occurPattern, 'List lines matching: ');
        } else {
          _pendingOccurQuery = _lastSearch;
          status = 'Occur: $_lastSearch';
        }
        return true;
      case 'swiper':
        _startSwiper();
        return true;

      // ---- Commands (extended) ------------------------------------------
      case 'executeExtendedCommand':
        _killRing.breakKillSequence();
        _openPrompt(_PromptKind.executeCommand, 'M-x ');
        return true;

      // ---- Editing (delegated to EditOps) ------------------------------
      case 'commentDwim':
        _commentDwim();
        return true;
      case 'fillParagraph':
        // Non-org-aware fallback: the org-mode-aware skip (heading/table/
        // block) lives in the editor widget, which knows whether the
        // current buffer is org-mode and re-runs `TextFill.fillParagraph`
        // with `orgMode: true` before this ever fires.
        _fillParagraph();
        return true;
      case 'zapToChar':
        // No breakKillSequence here: the kill sequence must stay open so that
        // consecutive M-z's append into one kill-ring entry (_zapToChar owns
        // the decision once the char arrives).
        _openPrompt(_PromptKind.zapToChar, 'Zap to char: ');
        return true;
      case 'transposeWords':
        _transposeWords();
        return true;
      case 'transposeLines':
        _transposeLines();
        return true;

      // ---- Registers ---------------------------------------------------
      case 'copyToRegister':
        _killRing.breakKillSequence();
        _openPrompt(_PromptKind.copyToRegister, 'Copy to register: ');
        return true;
      case 'insertRegister':
        _killRing.breakKillSequence();
        _openPrompt(_PromptKind.insertRegister, 'Insert register: ');
        return true;

      // ---- Keyboard macros ---------------------------------------------
      case 'startMacro':
        _killRing.breakKillSequence();
        _macros.start();
        status = 'Defining kbd macro...';
        return true;
      case 'endMacro':
        _killRing.breakKillSequence();
        if (!_macros.recording) {
          status = 'Not defining kbd macro';
          return true;
        }
        _macros.end();
        status = 'Keyboard macro defined (${_macros.replay().length} steps)';
        return true;
      case 'callMacro':
        _callMacro();
        return true;

      // ---- Rectangles ---------------------------------------------------
      case 'killRectangle':
        _killRectangle();
        return true;
      case 'yankRectangle':
        _yankRectangle();
        return true;

      // ---- Navigation ---------------------------------------------------
      case 'gotoLine':
        _killRing.breakKillSequence();
        _openPrompt(_PromptKind.gotoLine, 'Goto line: ');
        return true;
      case 'scrollUp':
        _scrollLines(_pageLines);
        status = 'Scroll up';
        return true;
      case 'scrollDown':
        _scrollLines(-_pageLines);
        status = 'Scroll down';
        return true;

      // ---- Buffers -------------------------------------------------------
      case 'listBuffers':
        // Report-only in the model (a host UI opens the *Buffer List* dialog);
        // this status is the graceful fallback when there is no host surface.
        _killRing.breakKillSequence();
        status =
            'Buffers: ${_buffers.keys.map((String n) => n == currentBuffer ? '$n (current)' : n).join(', ')}';
        return true;
      case 'switchBuffer':
        // C-x b — read a buffer name in the minibuffer, then switch/create.
        _killRing.breakKillSequence();
        _openPrompt(_PromptKind.switchBuffer, 'Switch to buffer: ');
        return true;
      case 'killBuffer':
        // C-x k — read a buffer name (empty = the current buffer), then kill.
        _killRing.breakKillSequence();
        _openPrompt(
            _PromptKind.killBuffer, 'Kill buffer (default $currentBuffer): ');
        return true;
      case 'nextBuffer':
        _cycleBuffer(1);
        return true;
      case 'previousBuffer':
        _cycleBuffer(-1);
        return true;

      // ---- Help (the widget opens the dialogs; report-only here) --------
      case 'describeBindings':
        _killRing.breakKillSequence();
        status = 'Describe bindings';
        return true;
      case 'whereIs':
        _killRing.breakKillSequence();
        status = 'Where is';
        return true;
      case 'aproposCommand':
        _killRing.breakKillSequence();
        status = 'Apropos command';
        return true;

      // ---- Report-only -------------------------------------------------
      case 'save':
        _killRing.breakKillSequence();
        status = 'Saved';
        return true;
      case 'openFile':
        _killRing.breakKillSequence();
        status = 'Open file';
        return true;
      case 'writeFile':
        _killRing.breakKillSequence();
        status = 'Write file';
        return true;
      case 'splitWindowBelow':
        _killRing.breakKillSequence();
        status = 'Split window below';
        return true;
      case 'splitWindowRight':
        _killRing.breakKillSequence();
        status = 'Split window right';
        return true;
      case 'deleteWindow':
        _killRing.breakKillSequence();
        status = 'Delete window';
        return true;
      case 'deleteOtherWindows':
        _killRing.breakKillSequence();
        status = 'Delete other windows';
        return true;
      case 'otherWindow':
        _killRing.breakKillSequence();
        status = 'Other window';
        return true;
      case 'help':
        _killRing.breakKillSequence();
        status = 'Help';
        return true;
      case 'browseKillRing':
        _killRing.breakKillSequence();
        status = 'Browse kill ring';
        return true;
      case 'babelExecute':
        _killRing.breakKillSequence();
        status = 'Execute source block';
        return true;
      case 'recenter':
        _killRing.breakKillSequence();
        status = 'Recenter';
        return true;
      case 'keyboardQuit':
        // C-g aborts a pending minibuffer prompt first (restoring the
        // pre-search caret) or an interactive query-replace walk, then
        // deactivates the mark.
        if (_qrSession != null) {
          queryReplaceRespond('q');
          return true;
        }
        if (_promptKind != null) promptCancel();
        _killRing.breakKillSequence();
        _mark.clear();
        status = 'Quit';
        return true;

      default:
        status = 'Unbound/unknown: $intentId';
        return false;
    }
  }

  void _breakAndMove(int target) {
    _killRing.breakKillSequence();
    _caret = target.clamp(0, _text.length);
  }

  void _killLine() {
    final span = TextMotions.killLineSpan(_text, _caret);
    final killed = _text.substring(span[0], span[1]);
    _pushUndo();
    _killRing.killAppend(killed);
    _text = _text.substring(0, span[0]) + _text.substring(span[1]);
    _mark.adjustForEdit(span[0], span[0] - span[1]);
    _caret = span[0];
    _lastYankRange = null;
    status = 'Killed line';
  }

  void _killWholeLine() {
    final start = TextMotions.lineStart(_text, _caret);
    var end = TextMotions.lineEnd(_text, _caret);
    if (end < _text.length) {
      end += 1; // include the trailing newline.
    }
    final killed = _text.substring(start, end);
    _pushUndo();
    _killRing.killAppend(killed);
    _text = _text.substring(0, start) + _text.substring(end);
    _mark.adjustForEdit(start, start - end);
    _caret = start;
    _lastYankRange = null;
    status = 'Killed whole line';
  }

  void _killRegion() {
    final r = region;
    if (r == null) {
      status = 'No region';
      return;
    }
    final killed = regionText!;
    _pushUndo();
    _killRing.kill(killed);
    _text = _text.substring(0, r.start) + _text.substring(r.end);
    _caret = r.start;
    _mark.clear();
    _lastYankRange = null;
    status = 'Killed region';
  }

  void _copyRegion() {
    final r = region;
    if (r == null) {
      status = 'No region';
      return;
    }
    _killRing.copy(regionText!);
    _mark.clear();
    status = 'Copied region';
  }

  void _deleteChar() {
    final span = TextMotions.deleteCharSpan(_text, _caret);
    if (span[0] == span[1]) {
      status = 'End of buffer';
      return;
    }
    _pushUndo();
    _text = _text.substring(0, span[0]) + _text.substring(span[1]);
    _mark.adjustForEdit(span[0], span[0] - span[1]);
    _caret = span[0];
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Deleted char';
  }

  void _deleteWordForward() {
    final span = TextMotions.deleteWordForwardSpan(_text, _caret);
    final killed = _text.substring(span[0], span[1]);
    _pushUndo();
    _killRing.killAppend(killed);
    _text = _text.substring(0, span[0]) + _text.substring(span[1]);
    _mark.adjustForEdit(span[0], span[0] - span[1]);
    _caret = span[0];
    _lastYankRange = null;
    status = 'Deleted word forward';
  }

  void _deleteWordBackward() {
    final span = TextMotions.deleteWordBackwardSpan(_text, _caret);
    final killed = _text.substring(span[0], span[1]);
    _pushUndo();
    _killRing.killAppend(killed, prepend: true);
    _text = _text.substring(0, span[0]) + _text.substring(span[1]);
    _mark.adjustForEdit(span[0], span[0] - span[1]);
    _caret = span[0];
    _lastYankRange = null;
    status = 'Deleted word backward';
  }

  void _yank() {
    final s = _killRing.yank();
    _pushUndo();
    final start = _caret;
    _text = _text.substring(0, _caret) + s + _text.substring(_caret);
    _mark.adjustForEdit(_caret, s.length);
    _caret += s.length;
    _lastYankRange = [start, start + s.length];
    status = 'Yank';
  }

  void _yankPop() {
    if (!_killRing.canYankPop || _lastYankRange == null) {
      status = 'Previous command was not a yank';
      return;
    }
    final t = _killRing.yankPop();
    if (t == null) {
      status = 'Previous command was not a yank';
      return;
    }
    final range = _lastYankRange!;
    _pushUndo();
    _text = _text.substring(0, range[0]) + t + _text.substring(range[1]);
    _mark.adjustForEdit(range[0], t.length - (range[1] - range[0]));
    _caret = range[0] + t.length;
    _lastYankRange = [range[0], range[0] + t.length];
    status = 'Yank pop';
  }

  void _openLine() {
    _pushUndo();
    _text = _text.substring(0, _caret) + '\n' + _text.substring(_caret);
    _mark.adjustForEdit(_caret, 1);
    // Caret intentionally NOT advanced.
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Open line';
  }

  void _transposeChars() {
    if (_text.length < 2) {
      status = 'Buffer too short to transpose';
      return;
    }
    int a;
    int b;
    if (_caret == _text.length && _caret >= 2) {
      a = _caret - 2;
      b = _caret - 1;
    } else if (_caret >= 1 && _caret < _text.length) {
      a = _caret - 1;
      b = _caret;
    } else {
      status = 'Cannot transpose here';
      return;
    }
    _pushUndo();
    final chars = _text.split('');
    final tmp = chars[a];
    chars[a] = chars[b];
    chars[b] = tmp;
    _text = chars.join();
    _caret = (_caret + 1).clamp(0, _text.length);
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Transpose chars';
  }

  String _upper(String s) => s.toUpperCase();
  String _lower(String s) => s.toLowerCase();

  String _titleCase(String s) {
    final buf = StringBuffer();
    var first = true;
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      final isAlpha = RegExp(r'[A-Za-z]').hasMatch(ch);
      if (isAlpha && first) {
        buf.write(ch.toUpperCase());
        first = false;
      } else if (isAlpha) {
        buf.write(ch.toLowerCase());
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  void _caseWord(String Function(String) transform) {
    final end = TextMotions.forwardWord(_text, _caret);
    final span = _text.substring(_caret, end);
    _pushUndo();
    _text = _text.substring(0, _caret) + transform(span) + _text.substring(end);
    _caret = end;
    _lastYankRange = null;
    _killRing.breakKillSequence();
  }

  /// Apply [transform] to the active region ([region], C-SPC mark) when one
  /// is set, else to the word at point (the same scoping [_caseWord] uses for
  /// `upcaseWord`/`downcaseWord`/`capitalizeWord`). Unlike [_caseWord] this is
  /// public and NOT limited to case transforms — it is the splice primitive
  /// an app-layer intent this model doesn't itself know about (e.g. the kit's
  /// kana-script keymap actions, `desktop_kit_kana_keymap.dart`) can reuse,
  /// so the app doesn't have to re-derive word/region-at-point handling and
  /// the undo/mark/kill-sequence bookkeeping every mutation needs.
  ///
  /// No-op (no undo pushed) when [transform] doesn't actually change the
  /// scoped text, or when the scope is empty (region collapsed to a point,
  /// or point at buffer end with no word ahead).
  void applyWordOrRegionEdit(String Function(String) transform) {
    final Region? r = region;
    final int start = r != null && !r.isEmpty ? r.start : _caret;
    final int end = r != null && !r.isEmpty
        ? r.end
        : TextMotions.forwardWord(_text, _caret);
    if (start >= end) return;
    final String span = _text.substring(start, end);
    final String next = transform(span);
    if (next == span) return;
    _pushUndo();
    _text = _text.substring(0, start) + next + _text.substring(end);
    _mark.adjustForEdit(start, next.length - span.length);
    _caret = start + next.length;
    _lastYankRange = null;
    _killRing.breakKillSequence();
  }

  void _justOneSpace() {
    var start = _caret;
    while (start > 0 && (_text[start - 1] == ' ' || _text[start - 1] == '\t')) {
      start--;
    }
    var end = _caret;
    while (end < _text.length && (_text[end] == ' ' || _text[end] == '\t')) {
      end++;
    }
    _pushUndo();
    _text = _text.substring(0, start) + ' ' + _text.substring(end);
    _mark.adjustForEdit(start, 1 - (end - start));
    _caret = start + 1;
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Just one space';
  }

  void _deleteHorizontalSpace() {
    var start = _caret;
    while (start > 0 && (_text[start - 1] == ' ' || _text[start - 1] == '\t')) {
      start--;
    }
    var end = _caret;
    while (end < _text.length && (_text[end] == ' ' || _text[end] == '\t')) {
      end++;
    }
    _pushUndo();
    _text = _text.substring(0, start) + _text.substring(end);
    _mark.adjustForEdit(start, start - end);
    _caret = start;
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Delete horizontal space';
  }

  void _undoOp() {
    if (_undo.isEmpty) {
      status = 'No further undo information';
      return;
    }
    final snap = _undo.removeLast();
    _pushSnapshot(_redo, _Snapshot(_text, _caret));
    _replaceText(snap.text, newCaret: snap.caret);
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Undo';
  }

  void _redoOp() {
    if (_redo.isEmpty) {
      status = 'No further redo information';
      return;
    }
    final snap = _redo.removeLast();
    _pushSnapshot(_undo, _Snapshot(_text, _caret));
    _replaceText(snap.text, newCaret: snap.caret);
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Redo';
  }

  // ================================================================ prefix arg

  /// C-u — start (or grow) the numeric prefix argument: 4, 16, 64 … The next
  /// [execute] repeats the command that many times when it is a motion or a
  /// kill, and otherwise simply consumes the argument.
  void universalArgument() {
    _killRing.breakKillSequence();
    final int? current = _pendingArg;
    _pendingArg = current == null ? 4 : current * 4;
    status = 'C-u $_pendingArg';
  }

  // ==================================================================== macros

  /// Append a step to an in-progress macro recording, unless this dispatch is
  /// itself a replay of one.
  void _recordStep(String step) {
    if (_replaying) return;
    _macros.record(step);
  }

  void _callMacro() {
    _killRing.breakKillSequence();
    if (_macros.recording) _macros.end(); // C-x e closes an open definition.
    final List<String> steps = _macros.replay();
    if (steps.isEmpty) {
      status = 'No kbd macro has been defined';
      return;
    }
    _replaying = true;
    try {
      for (final String step in steps) {
        if (step.startsWith('self-insert:')) {
          _insertRaw(step.substring('self-insert:'.length));
        } else {
          execute(step);
        }
      }
    } finally {
      _replaying = false;
    }
    status = 'Macro executed (${steps.length} steps)';
  }

  // =================================================================== prompts

  void _openPrompt(_PromptKind kind, String label) {
    _promptKind = kind;
    _promptLabel = label;
    _promptInput = '';
    _promptCaret = 0;
    _promptUndo.clear();
    status = label;
  }

  void _clearPrompt() {
    _promptKind = null;
    _promptLabel = '';
    _promptInput = '';
    _promptCaret = 0;
    _promptUndo.clear();
    _searchHits = const <SearchHit>[];
    _searchIndex = -1;
    _swiperResult = null;
    _swiperSelected = -1;
    _completionProvider = null;
    _completionCandidates = const <String>[];
    _completionSelected = -1;
  }

  /// Snapshot the prompt's current `(text, caret)` onto [_promptUndo] before
  /// an edit changes it — the prompt analogue of [_pushUndo]. Called by
  /// every prompt-editing verb; [promptUndo] pops it back.
  void _pushPromptUndo() {
    _pushSnapshot(_promptUndo, _Snapshot(_promptInput, _promptCaret));
  }

  /// The command id an `executeCommand` prompt (M-x) most recently accepted,
  /// or null. Reading it clears it — a one-shot handoff to the host, which
  /// decides whether the id is runnable and executes it.
  String? takePendingCommand() {
    final String? c = _pendingCommand;
    _pendingCommand = null;
    return c;
  }

  /// The pattern an `occur` intent most recently accepted, or null. Reading
  /// it clears it — a one-shot handoff to the host, which owns the
  /// `*Occur*` dialog.
  String? takePendingOccurQuery() {
    final String? q = _pendingOccurQuery;
    _pendingOccurQuery = null;
    return q;
  }

  /// Re-run [_completionProvider] against [_promptInput] and reset the strip
  /// selection. No-op when no provider is installed.
  void _recomputeCompletion() {
    final List<String> Function(String)? provider = _completionProvider;
    if (provider == null) return;
    _completionCandidates = provider(_promptInput);
    _completionSelected = -1;
  }

  /// TAB in a completing prompt: first completes [_promptInput] to the
  /// longest common prefix of the current candidates (as
  /// [CompletionModel.complete] does); a second TAB with the prefix
  /// unchanged instead cycles which candidate the strip highlights. No-op
  /// when the active prompt does not offer completion.
  void promptTab() {
    final List<String> Function(String)? provider = _completionProvider;
    if (provider == null) return;
    final List<String> current = provider(_promptInput);
    _completionCandidates = current;
    if (current.isEmpty) {
      _completionSelected = -1;
      status = 'No match: $_promptInput';
      return;
    }
    final String completed = CompletionModel(current).complete(_promptInput);
    if (completed != _promptInput) {
      _promptInput = completed;
      _promptCaret = _promptInput.length;
      _completionCandidates = provider(_promptInput);
      _completionSelected = -1;
    } else {
      _completionSelected =
          (_completionSelected + 1) % _completionCandidates.length;
    }
    status = prompt!;
  }

  /// ArrowDown in a completing prompt — highlight the next candidate,
  /// wrapping. No-op when there are no candidates.
  void completionSelectNext() {
    if (_completionCandidates.isEmpty) return;
    _completionSelected =
        (_completionSelected + 1) % _completionCandidates.length;
  }

  /// ArrowUp in a completing prompt — highlight the previous candidate,
  /// wrapping. No-op when there are no candidates.
  void completionSelectPrevious() {
    if (_completionCandidates.isEmpty) return;
    _completionSelected =
        (_completionSelected - 1 + _completionCandidates.length) %
            _completionCandidates.length;
  }

  /// The text RET should act on: the highlighted candidate when one is
  /// selected, otherwise whatever was typed.
  String _effectiveCompletionInput() {
    if (_completionSelected >= 0 &&
        _completionSelected < _completionCandidates.length) {
      return _completionCandidates[_completionSelected];
    }
    return _promptInput;
  }

  /// After any edit that changed [_promptInput], re-run the side effect the
  /// active prompt needs (re-search for isearch, re-filter for swiper,
  /// re-compute completion + refresh the status line for the rest). Factored
  /// out so [promptChar], [promptBackspace], [promptKillLine] and
  /// [promptDeleteChar] all stay in lockstep.
  void _afterPromptEdit() {
    final _PromptKind? kind = _promptKind;
    if (kind == null) return;
    if (isearching) {
      _updateSearch(_preSearchCaret, backward: _isearchBackward);
    } else if (kind == _PromptKind.swiper) {
      _recomputeSwiper();
    } else {
      if (_completionProvider != null) _recomputeCompletion();
      status = prompt!;
    }
  }

  /// Feed one character to the active prompt. The single-character prompts
  /// (M-z, C-x r s, C-x r i) complete immediately, as in Emacs; the rest
  /// insert at [promptCaret] (which normally sits at the end, so ordinary
  /// typing still appends) and accumulate until [promptAccept]. No-op when no
  /// prompt is active.
  void promptChar(String ch) {
    final _PromptKind? kind = _promptKind;
    if (kind == null || ch.isEmpty) return;

    if (kind == _PromptKind.zapToChar) {
      _clearPrompt();
      _zapToChar(ch);
      return;
    }
    if (kind == _PromptKind.copyToRegister) {
      _clearPrompt();
      _copyToRegister(ch);
      return;
    }
    if (kind == _PromptKind.insertRegister) {
      _clearPrompt();
      _insertRegister(ch);
      return;
    }

    _pushPromptUndo();
    final int at = _promptCaret.clamp(0, _promptInput.length);
    _promptInput =
        _promptInput.substring(0, at) + ch + _promptInput.substring(at);
    _promptCaret = at + ch.length;
    _afterPromptEdit();
  }

  /// C-y in the minibuffer — insert [text] (the kill-ring head; the host
  /// supplies it — see [EmacsBuffer.promptChar]'s doc for why this buffer
  /// does not read the kill ring or the system clipboard itself) at
  /// [promptCaret] in ONE step, so a single [promptUndo] undoes the whole
  /// yank rather than one code unit at a time. No-op when no prompt is open
  /// or [text] is empty.
  void promptYank(String text) {
    if (_promptKind == null || text.isEmpty) return;
    _pushPromptUndo();
    final int at = _promptCaret.clamp(0, _promptInput.length);
    _promptInput =
        _promptInput.substring(0, at) + text + _promptInput.substring(at);
    _promptCaret = at + text.length;
    _afterPromptEdit();
  }

  /// Erase the character before [promptCaret] (C-h / Backspace / Rubout),
  /// re-searching when this is an isearch (or re-filtering when this is
  /// swiper). No-op when the prompt is empty/inactive or the caret is already
  /// at the line start.
  void promptBackspace() {
    final _PromptKind? kind = _promptKind;
    if (kind == null || _promptInput.isEmpty) return;
    final int at = _promptCaret.clamp(0, _promptInput.length);
    if (at == 0) return;
    _pushPromptUndo();
    _promptInput =
        _promptInput.substring(0, at - 1) + _promptInput.substring(at);
    _promptCaret = at - 1;
    _afterPromptEdit();
  }

  /// C-b — move the minibuffer caret one character left. No-op at the start
  /// (or when no prompt is open).
  void promptMoveCharBackward() {
    if (_promptKind == null) return;
    if (_promptCaret > 0) _promptCaret -= 1;
  }

  /// C-f — move the minibuffer caret one character right. No-op at the end
  /// (or when no prompt is open).
  void promptMoveCharForward() {
    if (_promptKind == null) return;
    if (_promptCaret < _promptInput.length) _promptCaret += 1;
  }

  /// C-a — move the minibuffer caret to the start of the input.
  void promptMoveLineStart() {
    if (_promptKind == null) return;
    _promptCaret = 0;
  }

  /// C-e — move the minibuffer caret to the end of the input.
  void promptMoveLineEnd() {
    if (_promptKind == null) return;
    _promptCaret = _promptInput.length;
  }

  /// C-k — kill from the caret to the end of the minibuffer input. No-op when
  /// the caret is already at the end (or no prompt is open).
  void promptKillLine() {
    if (_promptKind == null) return;
    final int at = _promptCaret.clamp(0, _promptInput.length);
    if (at >= _promptInput.length) return;
    _pushPromptUndo();
    _promptInput = _promptInput.substring(0, at);
    _promptCaret = at;
    _afterPromptEdit();
  }

  /// C-d — delete the character *at* the caret (forward delete). No-op when the
  /// caret is at the end (or no prompt is open).
  void promptDeleteChar() {
    if (_promptKind == null) return;
    final int at = _promptCaret.clamp(0, _promptInput.length);
    if (at >= _promptInput.length) return;
    _pushPromptUndo();
    _promptInput =
        _promptInput.substring(0, at) + _promptInput.substring(at + 1);
    _promptCaret = at;
    _afterPromptEdit();
  }

  /// C-/ (the host also aliases C-_ and C-x u to the same intent as buffer
  /// undo — see the model-prompt key dispatch) — undo the last edit made
  /// INSIDE the active prompt. Pops [_promptUndo] only; NEVER touches the
  /// buffer's own [undo] stack, so undoing in the minibuffer can never undo a
  /// buffer edit made before (or while) the prompt is open. No-op when no
  /// prompt is open; reports "No further undo information" (matching
  /// [_undoOp]'s buffer-undo message) when the prompt has nothing left to
  /// undo.
  void promptUndo() {
    if (_promptKind == null) return;
    if (_promptUndo.isEmpty) {
      status = 'No further undo information';
      return;
    }
    final _Snapshot snap = _promptUndo.removeLast();
    _promptInput = snap.text;
    _promptCaret = snap.caret.clamp(0, _promptInput.length);
    _afterPromptEdit();
  }

  /// C-g — abandon the prompt, restoring the pre-search caret for an isearch
  /// (or the pre-swiper point for swiper).
  void promptCancel() {
    if (_promptKind == null) return;
    if (isearching) {
      _caret = _preSearchCaret.clamp(0, _text.length);
    } else if (_promptKind == _PromptKind.swiper) {
      _caret = _preSwiperCaret.clamp(0, _text.length);
    }
    _clearPrompt();
    status = 'Quit';
  }

  /// RET — commit whatever the active prompt was reading.
  void promptAccept() {
    if (_promptKind == null) return;
    final _PromptKind kind = _promptKind!;
    final String input = _promptInput;

    switch (kind) {
      case _PromptKind.isearchForward:
      case _PromptKind.isearchBackward:
      case _PromptKind.isearchForwardRegexp:
      case _PromptKind.isearchBackwardRegexp:
        // The caret already sits on the current hit — just leave it there.
        if (input.isNotEmpty) _lastSearch = input;
        _clearPrompt();
        status = input.isEmpty ? 'Quit' : 'Mark saved where search started';
        return;
      case _PromptKind.queryReplaceFrom:
        if (input.isEmpty) {
          _clearPrompt();
          status = 'Quit';
          return;
        }
        _queryReplaceFrom = input;
        _openPrompt(_PromptKind.queryReplaceWith, 'with: ');
        return;
      case _PromptKind.queryReplaceWith:
        final String from = _queryReplaceFrom;
        _clearPrompt();
        _startQueryReplace(from, input, regex: _queryReplaceRegex);
        return;
      case _PromptKind.gotoLine:
        _clearPrompt();
        _gotoLine(input);
        return;
      case _PromptKind.switchBuffer:
        final String name = _effectiveCompletionInput();
        _clearPrompt();
        if (name.isEmpty) {
          status = 'Quit';
          return;
        }
        // switch-to-buffer creates the buffer when it does not yet exist.
        newBuffer(name);
        return;
      case _PromptKind.killBuffer:
        _clearPrompt();
        killBufferNamed(input.isEmpty ? currentBuffer : input);
        return;
      case _PromptKind.zapToChar:
      case _PromptKind.copyToRegister:
      case _PromptKind.insertRegister:
        // Single-character prompts never reach RET (see [promptChar]).
        _clearPrompt();
        status = 'Quit';
        return;
      case _PromptKind.swiper:
        // The caret already sits on the previewed candidate — just land it.
        _clearPrompt();
        status = 'swiper: landed';
        return;
      case _PromptKind.occurPattern:
        _clearPrompt();
        if (input.isEmpty) {
          status = 'Quit';
          return;
        }
        _lastSearch = input;
        _pendingOccurQuery = input;
        status = 'Occur: $input';
        return;
      case _PromptKind.executeCommand:
        final String cmd = _effectiveCompletionInput();
        _clearPrompt();
        if (cmd.isEmpty) {
          status = 'Quit';
          return;
        }
        _pendingCommand = cmd;
        status = 'M-x $cmd';
        return;
    }
  }

  // ==================================================================== search

  void _startIsearch({required bool backward, bool regex = false}) {
    _killRing.breakKillSequence();
    final _PromptKind kind = regex
        ? (backward
            ? _PromptKind.isearchBackwardRegexp
            : _PromptKind.isearchForwardRegexp)
        : (backward ? _PromptKind.isearchBackward : _PromptKind.isearchForward);
    final String label = regex
        ? (backward ? 'Regexp I-search backward: ' : 'Regexp I-search: ')
        : (backward ? 'I-search backward: ' : 'I-search: ');

    if (isearching) {
      // A second C-s / C-r: repeat rather than restart. With nothing typed
      // yet, reuse the previous search string (as Emacs does).
      _promptKind = kind;
      _promptLabel = label;
      if (_promptInput.isEmpty) {
        if (_lastSearch.isEmpty) {
          status = label;
          return;
        }
        _promptInput = _lastSearch;
        _promptCaret = _promptInput.length;
        _updateSearch(_preSearchCaret, backward: backward);
      } else {
        _updateSearch(_caret, backward: backward);
      }
      return;
    }

    _preSearchCaret = _caret;
    _promptKind = kind;
    _promptLabel = label;
    _promptInput = '';
    _promptCaret = 0;
    _searchHits = const <SearchHit>[];
    _searchIndex = -1;
    status = label;
  }

  /// Re-run the incremental search for the prompt's current string, starting
  /// at [from], and move the caret onto the hit found (its end when searching
  /// forward, its start when searching backward — where Emacs leaves point).
  void _updateSearch(int from, {required bool backward}) {
    final String needle = _promptInput;
    final bool regex = _isearchRegex;
    if (needle.isEmpty) {
      _searchHits = const <SearchHit>[];
      _searchIndex = -1;
      _caret = _preSearchCaret.clamp(0, _text.length);
      status = _promptLabel;
      return;
    }
    if (regex) {
      // A regexp that will not compile surfaces its error and leaves point
      // exactly where it was — an incomplete pattern must never crash or jump.
      // Tested on `ok`, not on `regex != null`: under an engine that is not
      // Dart's RegExp there is no RegExp to hand back, so a null there no
      // longer means "did not compile" — see RegexCompileResult.
      final RegexCompileResult compiled = RegexSearch.compile(needle);
      if (!compiled.ok) {
        _searchHits = const <SearchHit>[];
        _searchIndex = -1;
        status = compiled.error ?? _promptLabel;
        return;
      }
      _searchHits = RegexSearch.matches(_text, needle);
      final SearchHit? hit = backward
          ? RegexSearch.backward(_text, from, needle)
          : RegexSearch.forward(_text, from, needle);
      if (hit == null) {
        _searchIndex = -1;
        status = 'Failing $_promptLabel$needle';
        return;
      }
      _caret = (backward ? hit.start : hit.end).clamp(0, _text.length);
      _searchIndex = _indexOfHit(hit);
      status = '$_promptLabel$needle';
      return;
    }
    _searchHits = Search.matches(_text, needle);
    final SearchHit? hit = backward
        ? Search.backward(_text, from, needle)
        : Search.forward(_text, from, needle);
    if (hit == null) {
      _searchIndex = -1;
      status = 'Failing $_promptLabel$needle';
      return;
    }
    _caret = (backward ? hit.start : hit.end).clamp(0, _text.length);
    _searchIndex = _indexOfHit(hit);
    status = '$_promptLabel$needle';
  }

  /// Index of the enumerated hit containing [hit]'s start, or -1. Not simply
  /// `indexOf`: [Search.forward] can land on an overlapping match that the
  /// non-overlapping enumeration in [searchHits] skips.
  int _indexOfHit(SearchHit hit) {
    for (var i = 0; i < _searchHits.length; i++) {
      if (_searchHits[i].start <= hit.start && hit.start < _searchHits[i].end) {
        return i;
      }
    }
    return -1;
  }

  /// Begin an interactive query-replace walk from point. Enters the per-match
  /// mode ([queryReplacing]) when there is at least one match; otherwise reports
  /// the miss (or a compile error, for a bad regexp) and stays out of the walk.
  ///
  /// The whole walk collapses into a SINGLE undo step (recorded in
  /// [_finishQueryReplace]); the buffer text updates live after every decision.
  void _startQueryReplace(String from, String with_, {required bool regex}) {
    _killRing.breakKillSequence();
    if (from.isEmpty) {
      status = 'Quit';
      return;
    }
    _lastSearch = from;
    final QueryReplaceSession session =
        QueryReplaceSession(_text, _caret, from, with_, regex: regex);
    if (session.error != null) {
      status = session.error!; // e.g. 'Invalid regexp: …'
      return;
    }
    if (session.current == null) {
      status = 'No occurrences of "$from"';
      return;
    }
    _qrSession = session;
    _qrFrom = from;
    _qrWith = with_;
    _qrOrigText = _text;
    _qrOrigCaret = _caret;
    _syncQrHighlight();
    status = queryReplacePrompt!;
  }

  /// Feed one decision to the interactive query-replace walk: `y`/space replace
  /// and advance, `n` skip, `!` replace the rest, `q` quit. Any other key is a
  /// no-op that keeps the walk open. No-op when [queryReplacing] is false.
  void queryReplaceRespond(String key) {
    final QueryReplaceSession? s = _qrSession;
    if (s == null) return;
    switch (key) {
      case 'y':
      case ' ':
        s.replaceCurrent();
      case 'n':
        s.skip();
      case '!':
        s.replaceAll();
      case 'q':
        s.quit();
      default:
        return; // Unrecognised response — stay in the walk.
    }
    _text = s.text;
    _caret = _caret.clamp(0, _text.length);
    if (s.done) {
      _finishQueryReplace(s);
    } else {
      _syncQrHighlight();
      status = queryReplacePrompt!;
    }
  }

  /// Point the live search highlight at the walk's current match (reusing the
  /// [searchHits] / current-hit rendering the host already paints).
  void _syncQrHighlight() {
    final QueryReplaceSession? s = _qrSession;
    final SearchHit? hit = s?.current;
    if (hit == null) {
      _searchHits = const <SearchHit>[];
      _searchIndex = -1;
      return;
    }
    _searchHits = <SearchHit>[hit];
    _searchIndex = 0;
    _caret = hit.end.clamp(0, _text.length);
  }

  /// End the walk: record the single collapsed undo step (only when something
  /// was replaced) and report the tally.
  void _finishQueryReplace(QueryReplaceSession s) {
    final int n = s.replacedCount;
    if (n > 0) {
      // One undo step for the whole walk: snapshot the pre-walk buffer. The
      // live [_text] already holds the fully-replaced result.
      _pushSnapshot(_undo, _Snapshot(_qrOrigText, _qrOrigCaret));
      _redo.clear();
      _lastYankRange = null;
    }
    _qrSession = null;
    _searchHits = const <SearchHit>[];
    _searchIndex = -1;
    status = 'Replaced $n occurrence${n == 1 ? '' : 's'}';
  }

  // ===================================================================== swiper

  /// M-s s — start the live filtered line search: every line is initially a
  /// candidate, with the selection previewing the candidate nearest point.
  void _startSwiper() {
    _killRing.breakKillSequence();
    _preSwiperCaret = _caret;
    _promptKind = _PromptKind.swiper;
    _promptLabel = 'swiper: ';
    _promptInput = '';
    _promptCaret = 0;
    _swiperSelected = -1;
    _recomputeSwiper();
  }

  /// Re-run [computeSwiper] for the current prompt input, then re-select the
  /// candidate nearest the pre-swiper point (Emacs swiper preserves the
  /// original point across filtering, not the already-previewed one) and
  /// preview it.
  void _recomputeSwiper() {
    final SwiperResult r = computeSwiper(_text, _promptInput);
    _swiperResult = r;
    _searchHits = r.hits;
    final int n = r.lines.length;
    status = 'swiper: $n matches';
    if (n == 0) {
      _swiperSelected = -1;
      _searchIndex = -1;
      return;
    }
    final int pointLine = _lineIndexOf(_preSwiperCaret);
    int sel = r.lines.indexWhere((SwiperLine l) => l.line >= pointLine);
    if (sel < 0) sel = n - 1;
    _swiperSelected = sel;
    _previewSelection();
  }

  /// Move the caret to the currently-selected candidate — its match start
  /// when the input matched something on that line, otherwise the line
  /// start — and point [searchIndex] at that match for highlighting.
  void _previewSelection() {
    final SwiperResult? r = _swiperResult;
    if (r == null || _swiperSelected < 0 || _swiperSelected >= r.lines.length) {
      return;
    }
    final SwiperLine c = r.lines[_swiperSelected];
    final SearchHit? match = c.match;
    _caret = (match?.start ?? c.lineStart).clamp(0, _text.length);
    _searchIndex = match == null ? -1 : _indexOfHit(match);
  }

  /// C-n / ArrowDown while swiping — select the next candidate, wrapping.
  void swiperNext() {
    final SwiperResult? r = _swiperResult;
    if (!swiping || r == null || r.lines.isEmpty) return;
    _swiperSelected = (_swiperSelected + 1) % r.lines.length;
    _previewSelection();
  }

  /// C-p / ArrowUp while swiping — select the previous candidate, wrapping.
  void swiperPrevious() {
    final SwiperResult? r = _swiperResult;
    if (!swiping || r == null || r.lines.isEmpty) return;
    _swiperSelected = (_swiperSelected - 1 + r.lines.length) % r.lines.length;
    _previewSelection();
  }

  /// 0-based line index containing buffer offset [offset].
  int _lineIndexOf(int offset) {
    var line = 0;
    final int end = offset.clamp(0, _text.length);
    for (var i = 0; i < end; i++) {
      if (_text[i] == '\n') line++;
    }
    return line;
  }

  // =========================================================== EditOps glue

  /// Apply a whole-text replacement produced by a pure module, recording undo
  /// and keeping the mark anchored.
  ///
  /// The mark is adjusted from the first differing offset, which is exact for
  /// the single-splice edits this is used for (comment, zap, transpose,
  /// replace). Multi-splice edits (rectangles) must not use this.
  void _applyEdit(String newText, int newCaret, {bool breakKill = true}) {
    _pushUndo();
    _mark.adjustForEdit(
        _firstDiff(_text, newText), newText.length - _text.length);
    _replaceText(newText, newCaret: newCaret);
    _lastYankRange = null;
    if (breakKill) _killRing.breakKillSequence();
  }

  /// Offset of the first character where [a] and [b] differ, or the length of
  /// the shorter when one is a prefix of the other.
  static int _firstDiff(String a, String b) {
    final int n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a.codeUnitAt(i) != b.codeUnitAt(i)) return i;
    }
    return n;
  }

  void _commentDwim() {
    final ({String text, int caret}) r =
        EditOps.commentDwim(_text, _caret, ';');
    if (r.text == _text) {
      _killRing.breakKillSequence();
      _caret = r.caret.clamp(0, _text.length);
      status = 'Nothing to comment';
      return;
    }
    _applyEdit(r.text, r.caret);
    status = 'Comment DWIM';
  }

  void _fillParagraph() {
    final OrgEdit r = TextFill.fillParagraph(_text, _caret);
    if (r.text == _text) {
      _killRing.breakKillSequence();
      _caret = r.caret.clamp(0, _text.length);
      status = 'Nothing to fill';
      return;
    }
    _applyEdit(r.text, r.caret);
    status = 'Filled paragraph';
  }

  void _zapToChar(String ch) {
    final ({String text, int caret, String killed}) r =
        EditOps.zapToCharKill(_text, _caret, ch);
    if (r.killed.isEmpty) {
      _killRing.breakKillSequence();
      status = 'Zap: no "$ch" after point';
      return;
    }
    // Keep the kill sequence open so consecutive M-z's append, as in Emacs.
    _applyEdit(r.text, r.caret, breakKill: false);
    _killRing.killAppend(r.killed);
    status = 'Zapped to "$ch"';
  }

  void _transposeWords() {
    final ({String text, int caret}) r = EditOps.transposeWords(_text, _caret);
    if (r.text == _text) {
      _killRing.breakKillSequence();
      status = 'Nothing to transpose';
      return;
    }
    _applyEdit(r.text, r.caret);
    status = 'Transpose words';
  }

  void _transposeLines() {
    final ({String text, int caret}) r = EditOps.transposeLines(_text, _caret);
    if (r.text == _text) {
      _killRing.breakKillSequence();
      status = 'Nothing to transpose';
      return;
    }
    _applyEdit(r.text, r.caret);
    status = 'Transpose lines';
  }

  void _gotoLine(String input) {
    _killRing.breakKillSequence();
    final int? n = int.tryParse(input.trim());
    if (n == null) {
      status = 'Invalid line number: $input';
      return;
    }
    // Caret-only: gotoLine never touches the text, so there is nothing to undo.
    _caret = EditOps.gotoLine(_text, n).caret.clamp(0, _text.length);
    status = 'Goto line $n';
  }

  void _scrollLines(int lines) {
    _killRing.breakKillSequence();
    var c = _caret;
    for (var i = 0; i < lines.abs(); i++) {
      final int next = lines > 0
          ? TextMotions.nextLine(_text, c)
          : TextMotions.previousLine(_text, c);
      if (next == c) break; // Hit the end of the buffer.
      c = next;
    }
    _caret = c.clamp(0, _text.length);
  }

  // ================================================================ registers

  void _copyToRegister(String name) {
    final String? t = regionText;
    if (t == null) {
      status = 'No region';
      return;
    }
    _registers.put(name, t);
    _mark.clear();
    status = 'Copied region to register $name';
  }

  void _insertRegister(String name) {
    final String? v = _registers.get(name);
    if (v == null) {
      status = 'Register $name is empty';
      return;
    }
    _insertRaw(v);
    status = 'Inserted register $name';
  }

  // =============================================================== rectangles

  void _killRectangle() {
    final int? m = _mark.mark;
    if (m == null) {
      status = 'No region';
      return;
    }
    final ({String text, int caret, List<String> rect}) r =
        EditOps.killRectangle(_text, m, _caret);
    _pushUndo();
    _rectangle = r.rect;
    _replaceText(r.text, newCaret: r.caret);
    // A rectangle is a splice per line, so the mark cannot be re-anchored with
    // a single offset+delta — Emacs deactivates it here anyway.
    _mark.clear();
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Killed rectangle (${r.rect.length} lines)';
  }

  void _yankRectangle() {
    if (_rectangle.isEmpty) {
      status = 'No rectangle to yank';
      return;
    }
    final ({String text, int caret}) r =
        EditOps.yankRectangle(_text, _caret, _rectangle);
    _pushUndo();
    _replaceText(r.text, newCaret: r.caret);
    _mark.clear(); // Multi-line splice — see [_killRectangle].
    _lastYankRange = null;
    _killRing.breakKillSequence();
    status = 'Yanked rectangle (${_rectangle.length} lines)';
  }

  // ================================================================== buffers

  /// Make [name] current, saving this buffer's text+caret first. No-op with a
  /// status when [name] does not exist.
  ///
  /// Text and caret are per-buffer, held on the [Buffer] object this simply
  /// repoints at — nothing is copied in either direction.
  ///
  /// Undo/redo history and the mark are buffer-local and travel WITH the
  /// buffer object, so a switch neither copies nor discards them.
  void switchToBuffer(String name) {
    if (name == currentBuffer) {
      status = 'Already in $name';
      return;
    }
    final Buffer? target = _buffers[name];
    if (target == null) {
      status = 'No such buffer: $name';
      return;
    }
    // No copy-out and no copy-in: the buffer we are leaving IS the object in
    // the map, and the one we are entering is the object we now point at.
    // Clamping stays, since a caret can outlive a shrink from appendToNamed.
    _select(target);
    target.caret = target.caret.clamp(0, target.text.length);
    _resetSessionStateOnSwitch();
    status = 'Switched to $name';
  }

  /// The ONLY place [_current] is assigned, so no path can move the selection
  /// without [onSelectionChanged] firing. A second assignment site is exactly
  /// how the selected window's pointer went stale before this phase.
  void _select(Buffer buffer) {
    if (identical(buffer, _current)) return;
    _current = buffer;
    onSelectionChanged?.call(buffer);
  }

  /// Create [name] (empty) and switch to it. Switches without clobbering when
  /// a buffer of that name already exists.
  void newBuffer(String name) {
    if (_buffers.containsKey(name)) {
      switchToBuffer(name);
      return;
    }
    final Buffer created = Buffer(name, '', 0);
    _buffers[name] = created;
    _select(created);
    _resetSessionStateOnSwitch();
    status = 'New buffer $name';
  }

  /// Rename the CURRENT buffer to [to], as Emacs `rename-buffer` does.
  ///
  /// Buffer identity is what the buffer list, the mode line and `C-x b` all
  /// key on, so a document loaded from disk has to carry its own name — a
  /// host that leaves every file in `*scratch*` makes the buffer list report
  /// one buffer no matter how many files were opened.
  ///
  /// Uniquifies on collision the way Emacs does (`README.md`, `README.md<2>`,
  /// …) rather than clobbering or refusing: two files with the same basename
  /// in different directories is ordinary, not an error.
  void renameBuffer(String to) {
    final String wanted = to.trim();
    if (wanted.isEmpty || wanted == currentBuffer) {
      return;
    }
    final String unique = _uniqueBufferName(wanted);
    // RE-KEY THE SAME OBJECT — never construct a new one. Buffer identity is
    // what folds, marks, undo stacks and (since this phase) every WINDOW hang
    // off; rebuilding here would silently drop everything a rename is supposed
    // to preserve.
    //
    // The buffer's own name and the index key move together, and the selection
    // is not touched at all: it is a reference to this very object, so it
    // needs no update. That is the whole benefit of the inversion — a rename
    // used to require finding and fixing every stored copy of the old name,
    // and the one nobody remembered was the window's.
    final Buffer renamed = _buffers.remove(currentBuffer)!;
    renamed.name = unique;
    _buffers[unique] = renamed;
    status = 'Renamed to $unique';
  }

  /// [base], or `base<n>` for the lowest n >= 2 that is free.
  String _uniqueBufferName(String base) {
    if (!_buffers.containsKey(base)) {
      return base;
    }
    for (int n = 2;; n++) {
      final String candidate = '$base<$n>';
      if (!_buffers.containsKey(candidate)) {
        return candidate;
      }
    }
  }

  /// Appends [chunk] to the buffer named [name] — the landing point for
  /// async/out-of-band output (e.g. a shell session's stdout) that must
  /// reach a buffer that may not be the current one. Appending to the
  /// CURRENT buffer extends [text] and moves the caret to the new end;
  /// appending to a background buffer only updates its stored entry, caret
  /// pinned to its new end too, so switching to it later lands at the
  /// bottom. Bypasses undo — this is process output, not a user edit.
  /// No-op with a status when [name] is not a live buffer.
  ///
  /// NOT real comint semantics, despite the resemblance (and despite this
  /// doc formerly claiming otherwise). This always inserts at the absolute
  /// END of [text] and always forces the caret there, with no notion of a
  /// process mark. That is exactly right for a read-only transcript nobody
  /// is typing into, and exactly wrong the instant somebody is: output
  /// arriving while a command is half-typed lands AFTER the characters
  /// already there, and the forced caret jump stops the next keystrokes from
  /// reaching them — a user typing `echo hi` while output was still arriving
  /// has had a shell receive only the tail, `ho hi`. A host whose buffer
  /// mixes async output with an editable pending line (a shell/REPL prompt)
  /// needs a real process mark and should splice with [appendToNamedAt]
  /// instead, supplying that mark itself — see its doc for why the kit does
  /// not derive one here.
  void appendToNamed(String name, String chunk) {
    if (chunk.isEmpty) return;
    // One path for current and background buffers alike — with live objects
    // there is no longer a distinction to special-case.
    final Buffer? target = _buffers[name];
    if (target == null) {
      status = 'No such buffer: $name';
      return;
    }
    target.text = target.text + chunk;
    target.caret = target.text.length;
    // Bypasses the `_text` setter (this may not be the CURRENT buffer), so
    // the modified flag needs the same one-line treatment here explicitly.
    target.modified = true;
  }

  /// Splices [chunk] into the buffer named [name] at [position] — the
  /// general mechanism real comint uses (output is inserted at a "process
  /// mark", ahead of the prompt and any not-yet-submitted input) for a host
  /// whose buffer mixes async output with an editable pending line, e.g. a
  /// shell/REPL prompt.
  ///
  /// Unlike [appendToNamed], which always appends at the end and forces the
  /// caret there, this inserts wherever [position] says and moves the caret
  /// only when it already sat at or after [position] — by exactly
  /// [chunk.length], so a caret in the middle of not-yet-submitted input
  /// keeps pointing at the same characters instead of jumping to the new
  /// text's end. That is what stops output arriving mid-typing from
  /// splitting the command being typed (see [appendToNamed]'s doc for the
  /// concrete failure this avoids).
  ///
  /// [position] is clamped into `[0, text.length]`. The kit deliberately
  /// does NOT compute [position] itself: where a process mark belongs —
  /// after the last newline for a line-oriented process, a stored offset for
  /// something else — is a property of the host's process protocol, not of
  /// the buffer, the same reason [Buffer.mode] is an opaque [Object?] rather
  /// than a kit-declared enum. (It is also deliberately NOT [Buffer.mark]:
  /// that is the Emacs region mark — `C-space` / [MarkState] — an unrelated
  /// concept that happens to share the English word.) A host with a
  /// line-oriented process — every write ends `\n`, so the final line is
  /// always exactly the prompt plus pending input — can derive [position] as
  /// `text.lastIndexOf('\n') + 1` (0 when there is no newline yet).
  ///
  /// Bypasses undo, like [appendToNamed] — this is process output, not a
  /// user edit. No-op with a status when [name] is not a live buffer.
  void appendToNamedAt(String name, int position, String chunk) {
    if (chunk.isEmpty) return;
    final Buffer? target = _buffers[name];
    if (target == null) {
      status = 'No such buffer: $name';
      return;
    }
    final int at = position.clamp(0, target.text.length);
    target.text = target.text.replaceRange(at, at, chunk);
    if (target.caret >= at) {
      target.caret = (target.caret + chunk.length).clamp(
        0,
        target.text.length,
      );
    }
    // Bypasses the `_text` setter (this may not be the CURRENT buffer), so
    // the modified flag needs the same one-line treatment here explicitly.
    target.modified = true;
  }

  /// Reset the state a buffer switch invalidates.
  ///
  /// This runs AFTER the selection has moved, which is why the mark, the
  /// yank range, and now undo/redo are conspicuously absent: all four are
  /// buffer-local, so clearing them here would wipe the state of the buffer
  /// being switched TO — the mechanism behind "the mark is lost when I switch
  /// buffers" (and, before this change, "undo forgets everything when I
  /// switch buffers"). They survive a switch because they live on [Buffer];
  /// see [Buffer.undo] / [Buffer.redo] for why moving them here was the last
  /// and riskiest step of the migration, not the first.
  ///
  /// The kill-sequence break and the prompt clear are genuine session state —
  /// consecutive kills must not append across a switch, and a half-typed
  /// minibuffer prompt does not belong to the buffer it was started from.
  void _resetSessionStateOnSwitch() {
    _killRing.breakKillSequence();
    _clearPrompt();
  }

  /// Kill the buffer named [name]. Killing the *current* buffer switches to
  /// another buffer first (Emacs semantics), so [text] is never left pointing
  /// at a removed entry; the sole remaining buffer cannot be killed.
  void killBufferNamed(String name) {
    _killRing.breakKillSequence();
    if (!_buffers.containsKey(name)) {
      status = 'No such buffer: $name';
      return;
    }
    if (_buffers.length <= 1) {
      status = 'Cannot kill the sole remaining buffer';
      return;
    }
    if (name == currentBuffer) {
      final List<String> names = _buffers.keys.toList();
      final int i = names.indexOf(name);
      // switchToBuffer repoints at the other buffer and resets session-local
      // state; nothing is copied, so the entry we remove below is inert.
      switchToBuffer(names[(i + 1) % names.length]);
    }
    // Undo/redo are buffer-local now (see [Buffer.undo]/[Buffer.redo]), and
    // switchToBuffer no longer clears them — it used to be the accidental
    // garbage collector for these stacks before they moved onto [Buffer].
    // Release explicitly rather than relying on `_buffers.remove` dropping
    // the last reference to the [Buffer] object: each snapshot holds a full
    // copy of this buffer's text, so leaving that to an implicit "nothing
    // else happens to hold a reference" invariant is exactly the kind of
    // thing a later refactor silently breaks.
    final Buffer killed = _buffers[name]!;
    killed.undo.clear();
    killed.redo.clear();
    _buffers.remove(name);
    status = 'Killed buffer $name';
  }

  /// Bury the buffer named [name]: send it to the END of the buffer list
  /// (Emacs `bury-buffer`) WITHOUT discarding anything about it.
  ///
  /// [bufferNames] and [bufferSnapshots] both derive from [_buffers]'
  /// iteration order (see the field doc), so "send to the bottom of the
  /// list" is exactly remove-then-reinsert on that map — no separate
  /// ordering field to maintain, and the [Buffer] object itself (text,
  /// caret, mark, undo/redo, defaultDirectory, visitedFile, …) is never
  /// touched. This is deliberately NOT `killBufferNamed` followed by
  /// `newBuffer`: that round-trip is a brand-new [Buffer] object, so it
  /// silently drops undo/redo (and everything else) exactly like any other
  /// kill+recreate — defeating the one reason this method exists, which is
  /// a caller (e.g. dired's `q`) that wants the buffer OFF SCREEN, not gone.
  ///
  /// Burying the *current* buffer switches away first, to the next buffer in
  /// ring order — the same target [killBufferNamed] switches to when the
  /// killed buffer is current. This model keeps no most-recently-used
  /// ordering (see [_cycleBuffer]), so ring order is the closest faithful
  /// reading of Emacs' "switch to `(other-buffer)`" available here, and
  /// reusing [killBufferNamed]'s own choice keeps the two buffer-list
  /// mutators agreeing on what "the next buffer" means.
  ///
  /// No-op with a status when [name] does not exist. Refuses — like
  /// [killBufferNamed] — to bury the sole remaining buffer: with one buffer
  /// there is nothing to reorder against and nowhere to switch away to.
  void buryBuffer(String name) {
    _killRing.breakKillSequence();
    if (!_buffers.containsKey(name)) {
      status = 'No such buffer: $name';
      return;
    }
    if (_buffers.length <= 1) {
      status = 'Cannot bury the sole remaining buffer';
      return;
    }
    if (name == currentBuffer) {
      final List<String> names = _buffers.keys.toList();
      final int i = names.indexOf(name);
      // switchToBuffer repoints at the other buffer and resets session-local
      // state; the reorder below leaves that object untouched.
      switchToBuffer(names[(i + 1) % names.length]);
    }
    // Remove + reinsert under the SAME key: Dart's Map preserves insertion
    // order, so re-adding a key places it at the current end. The [Buffer]
    // object is passed through unchanged — never copied, never rebuilt.
    final Buffer buried = _buffers.remove(name)!;
    _buffers[name] = buried;
    status = 'Buried buffer $name';
  }

  /// Number of undo snapshots retained for the buffer named [name], or null
  /// when no such buffer exists. @visibleForTesting: the depth cap and the
  /// kill-releases-the-stack invariant are internal implementation details a
  /// host UI has no reason to observe; tests need this to pin them down.
  @visibleForTesting
  int? undoDepthForBuffer(String name) => _buffers[name]?.undo.length;

  /// Number of redo snapshots retained for the buffer named [name], or null
  /// when no such buffer exists. @visibleForTesting — see [undoDepthForBuffer].
  @visibleForTesting
  int? redoDepthForBuffer(String name) => _buffers[name]?.redo.length;

  /// A readout of every buffer — name, whether it is current, and line count —
  /// for a host *Buffer List* UI. Every entry is live: a background buffer's
  /// line and byte counts are its real ones, not those of the last snapshot
  /// taken when it was switched away from.
  List<({String name, bool current, int lineCount, int byteCount})>
      bufferSnapshots() {
    int lines(String s) => '\n'.allMatches(s).length + 1;
    // UTF-8 bytes, not String.length (which counts UTF-16 code units): the
    // Bytes column claims to be a byte size, and a buffer full of kana would
    // otherwise under-report by ~3x. utf8.encode avoids materialising an
    // intermediate list twice by measuring directly.
    return <({String name, bool current, int lineCount, int byteCount})>[
      for (final MapEntry<String, Buffer> e in _buffers.entries)
        (
          name: e.key,
          current: identical(e.value, _current),
          lineCount: lines(e.value.text),
          byteCount: utf8.encode(e.value.text).length,
        ),
    ];
  }

  void _cycleBuffer(int delta) {
    _killRing.breakKillSequence();
    final List<String> names = _buffers.keys.toList();
    if (names.length < 2) {
      status = 'No other buffer';
      return;
    }
    final int i = names.indexOf(currentBuffer);
    switchToBuffer(names[(i + delta) % names.length]);
  }
}
