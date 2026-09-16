/// Headless Emacs-style text-buffer engine for desktop_kit.
///
/// A pure, Flutter-free model layer — caret motion, mark/region, kill-ring
/// integration, undo/redo, search/isearch, query-replace, registers, keyboard
/// macros, paragraph fill, buffer-list styling, and window-tree splitting —
/// operating on plain Dart `String`s. Promoted out of the eedit gallery app so
/// any host can drive an Emacs-style editor widget without re-implementing the
/// model.
///
/// Includes:
/// - [EmacsBuffer] — the buffer model; a widget owns the `TextEditingController`
///   and calls [EmacsBuffer.execute] per intent id
/// - [EditorBackend] — an OPTIONAL seam letting a subset of intents be driven
///   by something other than [EmacsBuffer]'s own Dart implementation (see
///   [EmacsBuffer.executeAsync]); unset, [EmacsBuffer.execute] is unconditionally
///   what runs, for every intent, for every host
/// - [EditOps] — pure editing commands (comment-dwim, zap, transpose, goto-line,
///   rectangles) — see `desktop_kit_editor.dart`'s `emacs_edit_ops.dart`
/// - search/replace ([EmacsSearch]-family) and [Swiper] (isearch-style
///   incremental search over a candidate list)
/// - [KillRing]-integrated kill/yank via [EmacsBuffer]; registers + keyboard
///   macros ([EmacsRegisters])
/// - [TextFill] paragraph fill/unfill
/// - [NarrowState] (`narrow-to-region` bookkeeping)
/// - [BufferListStyle] presentation model for a buffer-list UI
/// - [WindowTree] split/close/cycle-focus model for an Emacs-style window layout
///
/// Opt-in, like the anthy/kana bridges: NOT re-exported from `desktop_kit.dart`.
library;

export 'src/editor/buffer_menu.dart';
export 'src/editor/editor_backend.dart';
export 'src/editor/emacs_buffer.dart';
export 'src/editor/emacs_completion.dart';
export 'src/editor/emacs_edit_ops.dart';
export 'src/editor/emacs_registers.dart';
export 'src/editor/emacs_search.dart';
export 'src/editor/narrow_state.dart';
export 'src/editor/swiper.dart';
export 'src/editor/text_fill.dart';
export 'src/editor/window_tree.dart';
