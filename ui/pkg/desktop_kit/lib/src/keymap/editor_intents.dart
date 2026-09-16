// Intents for the Emacs/CUA editor keymap.
//
// Ported from notekeep + voicelab, stripped of every kana/IME intent — this
// package is IME-free. Each [Intent] is bound by a [ShortcutActivator] in the
// active keymap (see keymaps.dart) and dispatched by the host editor's key
// handler. Distinct types let the dispatcher route each to its own handler
// and let tests assert which intent a key yields.
library;

import 'package:flutter/widgets.dart';

// --- motions ---------------------------------------------------------------

/// C-a — move to the beginning of the current line.
class MoveLineStartIntent extends Intent {
  const MoveLineStartIntent();
}

/// C-e — move to the end of the current line.
class MoveLineEndIntent extends Intent {
  const MoveLineEndIntent();
}

/// M-< — move to the start of the buffer.
class MoveBufferStartIntent extends Intent {
  const MoveBufferStartIntent();
}

/// M-> — move to the end of the buffer.
class MoveBufferEndIntent extends Intent {
  const MoveBufferEndIntent();
}

/// C-f — move forward one character.
class MoveForwardCharIntent extends Intent {
  const MoveForwardCharIntent();
}

/// C-b — move backward one character.
class MoveBackwardCharIntent extends Intent {
  const MoveBackwardCharIntent();
}

/// C-n — move to the next line.
class MoveNextLineIntent extends Intent {
  const MoveNextLineIntent();
}

/// C-p — move to the previous line.
class MovePreviousLineIntent extends Intent {
  const MovePreviousLineIntent();
}

/// M-f — move forward one word.
class MoveForwardWordIntent extends Intent {
  const MoveForwardWordIntent();
}

/// M-b — move backward one word.
class MoveBackwardWordIntent extends Intent {
  const MoveBackwardWordIntent();
}

// --- kills / yank ----------------------------------------------------------

/// C-k — kill from point to end of line (kill-line).
class KillLineIntent extends Intent {
  const KillLineIntent();
}

/// Ctrl+Shift+Backspace — kill the entire current line, including its
/// terminating newline (kill-whole-line).
class KillWholeLineIntent extends Intent {
  const KillWholeLineIntent();
}

/// C-w — kill the active region (kill-region).
class KillRegionIntent extends Intent {
  const KillRegionIntent();
}

/// M-w — copy the active region into the kill ring (kill-ring-save).
class CopyRegionIntent extends Intent {
  const CopyRegionIntent();
}

/// C-d — delete the character after point (delete-char).
class DeleteCharIntent extends Intent {
  const DeleteCharIntent();
}

/// M-d — kill from point to the end of the next word (kill-word).
class DeleteWordForwardIntent extends Intent {
  const DeleteWordForwardIntent();
}

/// M-Backspace — kill the previous word (backward-kill-word).
class DeleteWordBackwardIntent extends Intent {
  const DeleteWordBackwardIntent();
}

/// C-y — yank (insert the kill ring's current entry).
class YankIntent extends Intent {
  const YankIntent();
}

/// M-y — yank-pop (rotate the ring after a yank).
class YankPopIntent extends Intent {
  const YankPopIntent();
}

/// Ctrl+Shift+Y — open the kill-ring browser dialog (most-recent first; tap
/// an entry to yank it). Available in both CUA and Emacs modes.
class BrowseKillRingIntent extends Intent {
  const BrowseKillRingIntent();
}

// --- mark ------------------------------------------------------------------

/// C-SPC — set the mark at point (set-mark-command).
class SetMarkIntent extends Intent {
  const SetMarkIntent();
}

/// C-x C-x — exchange point and mark (exchange-point-and-mark).
class ExchangePointAndMarkIntent extends Intent {
  const ExchangePointAndMarkIntent();
}

/// C-x h — mark the whole buffer (mark-whole-buffer).
class MarkWholeBufferIntent extends Intent {
  const MarkWholeBufferIntent();
}

/// C-x C-p — mark the page around point, bounded by form-feed characters
/// (mark-page). Selects the whole buffer when no form feeds exist.
class MarkPageIntent extends Intent {
  const MarkPageIntent();
}

// --- editing ---------------------------------------------------------------

/// C-/ (and C-_) / Ctrl+Z — undo the last edit.
class EditorUndoIntent extends Intent {
  const EditorUndoIntent();
}

/// Redo (CUA: Ctrl+Shift+Z / Ctrl+Y on Windows). Emacs has no native redo
/// — this intent is available for CUA hosts.
class EditorRedoIntent extends Intent {
  const EditorRedoIntent();
}

/// C-o — insert a newline after point without moving point (open-line).
class OpenLineIntent extends Intent {
  const OpenLineIntent();
}

/// C-t — transpose the characters before and after point (transpose-chars).
class TransposeCharsIntent extends Intent {
  const TransposeCharsIntent();
}

/// M-SPC — collapse surrounding whitespace to a single space
/// (just-one-space).
class JustOneSpaceIntent extends Intent {
  const JustOneSpaceIntent();
}

/// M-\ — delete all horizontal whitespace around point
/// (delete-horizontal-space).
class DeleteHorizontalSpaceIntent extends Intent {
  const DeleteHorizontalSpaceIntent();
}

/// C-l — recenter the view on point (recenter-top-bottom).
class RecenterIntent extends Intent {
  const RecenterIntent();
}

// --- terminal / whitespace translations ------------------------------------

/// C-j (LF) / C-m (CR) — insert a newline. The historical tty control-code
/// translation: Ctrl-J is line feed, Ctrl-M is carriage return, and RET maps
/// here too (electric-newline-and-maybe-indent / newline).
class NewlineIntent extends Intent {
  const NewlineIntent();
}

/// C-i (HT) — insert a tab. The historical tty control-code translation:
/// Ctrl-I is horizontal tab, and TAB maps here too (indent-for-tab-command).
class InsertTabIntent extends Intent {
  const InsertTabIntent();
}

// --- case ------------------------------------------------------------------

/// M-u — upcase the word after point (upcase-word).
class UpcaseWordIntent extends Intent {
  const UpcaseWordIntent();
}

/// M-l — downcase the word after point (downcase-word).
class DowncaseWordIntent extends Intent {
  const DowncaseWordIntent();
}

/// M-c — capitalize the word after point (capitalize-word).
class CapitalizeWordIntent extends Intent {
  const CapitalizeWordIntent();
}

// --- prefix / file ---------------------------------------------------------

/// C-x — begin a prefix chord. The editor's [PrefixDispatcher] then
/// interprets the next key (see prefix_dispatcher.dart).
class PrefixCtrlXIntent extends Intent {
  const PrefixCtrlXIntent();
}

/// C-s (standalone) or C-x C-s (chord completion) — save the buffer.
class SaveBufferIntent extends Intent {
  const SaveBufferIntent();
}

/// C-x C-f — open / find a file (find-file).
class OpenFileIntent extends Intent {
  const OpenFileIntent();
}

/// C-x C-w — write the buffer to a named file (write-file / "save as"). A
/// multi-stroke sequence; runtime dispatch is handled by the sequence matcher.
class WriteFileIntent extends Intent {
  const WriteFileIntent();
}

/// C-x b — switch to another buffer (switch-to-buffer). A multi-stroke
/// sequence: editor-visible and rebindable now; runtime dispatch is handled by
/// [PrefixDispatcher] (a sequence matcher arrives in a later step).
class SwitchBufferIntent extends Intent {
  const SwitchBufferIntent();
}

/// C-x k — kill (close) the current buffer (kill-buffer). A multi-stroke
/// sequence: editor-visible and rebindable now; runtime dispatch is handled by
/// [PrefixDispatcher] (a sequence matcher arrives in a later step).
class KillBufferIntent extends Intent {
  const KillBufferIntent();
}

// --- quit ------------------------------------------------------------------

/// C-g (keyboard-quit): deactivate the mark / collapse the region and cancel
/// any armed C-x prefix. Emacs mode only — CUA has no keyboard-quit notion.
class KeyboardQuitIntent extends Intent {
  const KeyboardQuitIntent();
}

/// C-x C-c — save-buffers-kill-terminal: exit the application.
///
/// **The contract is PROMPT, never force-save.** GNU Emacs asks about each
/// modified buffer (`Save file …? (y, n, !, ., q)`) and lets the user decline;
/// `q` or C-g aborts the exit entirely. A host that silently writes every
/// modified buffer and then quits is NOT implementing this intent — it is
/// implementing something the user cannot refuse, which is the behaviour this
/// intent exists to replace.
///
/// Report-only: the kit owns neither buffers nor the application lifecycle, so
/// the host performs the prompt and the exit. The required host behaviour is:
///
///   * no modified buffers → exit;
///   * one or more modified → prompt (per buffer, or once listing them) with at
///     least *save and exit*, *exit without saving*, and *cancel*;
///   * *cancel* leaves the application running and every buffer untouched.
class SaveBuffersKillTerminalIntent extends Intent {
  const SaveBuffersKillTerminalIntent();
}

// --- help ------------------------------------------------------------------

/// C-h / F1 — show a help overlay listing the active keymap's bindings.
class HelpIntent extends Intent {
  const HelpIntent();
}

/// C-h k — describe-key: capture the next key or chord and report what it is
/// bound to (contextual help). A prefix affordance; the host enters a
/// describe-next-key mode rather than editing the buffer.
class DescribeKeyIntent extends Intent {
  const DescribeKeyIntent();
}

// --- search / replace -------------------------------------------------------

/// C-s — incremental search forward (isearch-forward).
class IsearchForwardIntent extends Intent {
  const IsearchForwardIntent();
}

/// C-r — incremental search backward (isearch-backward).
class IsearchBackwardIntent extends Intent {
  const IsearchBackwardIntent();
}

/// C-M-s — incremental regexp search forward (isearch-forward-regexp).
class IsearchForwardRegexpIntent extends Intent {
  const IsearchForwardRegexpIntent();
}

/// C-M-r — incremental regexp search backward (isearch-backward-regexp).
class IsearchBackwardRegexpIntent extends Intent {
  const IsearchBackwardRegexpIntent();
}

/// M-% — query-replace: interactively replace each match, prompting per hit.
class QueryReplaceIntent extends Intent {
  const QueryReplaceIntent();
}

/// C-M-% — query-replace-regexp: interactively replace each regexp match,
/// prompting per hit, with capture-group substitution in the replacement.
class QueryReplaceRegexpIntent extends Intent {
  const QueryReplaceRegexpIntent();
}

/// M-x occur — list all lines matching a pattern in a dedicated buffer.
class OccurIntent extends Intent {
  const OccurIntent();
}

// --- editing (extended) -----------------------------------------------------

/// C-u — universal-argument: begin a numeric prefix argument for the next
/// command.
class UniversalArgumentIntent extends Intent {
  const UniversalArgumentIntent();
}

/// M-; — comment-dwim: comment or uncomment the region or current line.
class CommentDwimIntent extends Intent {
  const CommentDwimIntent();
}

/// M-q — fill-paragraph: reflow the paragraph at point to the fill column.
class FillParagraphIntent extends Intent {
  const FillParagraphIntent();
}

/// M-z — zap-to-char: kill from point up to and including the next
/// occurrence of a prompted character.
class ZapToCharIntent extends Intent {
  const ZapToCharIntent();
}

/// M-t — transpose-words: swap the words before and after point.
class TransposeWordsIntent extends Intent {
  const TransposeWordsIntent();
}

/// C-x C-t — transpose-lines: swap the current line with the previous one.
class TransposeLinesIntent extends Intent {
  const TransposeLinesIntent();
}

// --- registers ---------------------------------------------------------------

/// C-x r s — copy-to-register: store the region into a named register.
class CopyToRegisterIntent extends Intent {
  const CopyToRegisterIntent();
}

/// C-x r i — insert-register: insert the contents of a named register.
class InsertRegisterIntent extends Intent {
  const InsertRegisterIntent();
}

// --- macros ------------------------------------------------------------------

/// C-x ( — start-kbd-macro: begin recording a keyboard macro.
class StartMacroIntent extends Intent {
  const StartMacroIntent();
}

/// C-x ) — end-kbd-macro: stop recording the current keyboard macro.
class EndMacroIntent extends Intent {
  const EndMacroIntent();
}

/// C-x e — call-last-kbd-macro: replay the most recently defined macro.
class CallMacroIntent extends Intent {
  const CallMacroIntent();
}

// --- rectangles ----------------------------------------------------------------

/// C-x r k — kill-rectangle: delete the rectangular region between point and
/// mark, saving it for a later yank-rectangle.
class KillRectangleIntent extends Intent {
  const KillRectangleIntent();
}

/// C-x r y — yank-rectangle: insert the last killed rectangle at point.
class YankRectangleIntent extends Intent {
  const YankRectangleIntent();
}

// --- navigation (extended) ------------------------------------------------

/// M-g g — goto-line: prompt for a line number and move point there.
class GotoLineIntent extends Intent {
  const GotoLineIntent();
}

/// C-v — scroll-up-command: scroll the view forward by roughly one page.
class ScrollUpIntent extends Intent {
  const ScrollUpIntent();
}

/// M-v — scroll-down-command: scroll the view backward by roughly one page.
class ScrollDownIntent extends Intent {
  const ScrollDownIntent();
}

// --- buffers (extended) -----------------------------------------------------

/// C-x C-b — list-buffers: show the buffer list.
class ListBuffersIntent extends Intent {
  const ListBuffersIntent();
}

/// C-x right-arrow (bracketed here as its own intent) — next-buffer: switch
/// to the next buffer in the buffer list.
class NextBufferIntent extends Intent {
  const NextBufferIntent();
}

/// C-x left-arrow (bracketed here as its own intent) — previous-buffer:
/// switch to the previous buffer in the buffer list.
class PreviousBufferIntent extends Intent {
  const PreviousBufferIntent();
}

// --- help (extended) ---------------------------------------------------------

/// C-h b — describe-bindings: list all current key bindings in a help
/// buffer.
class DescribeBindingsIntent extends Intent {
  const DescribeBindingsIntent();
}

/// C-h w — where-is: prompt for a command and report which key(s) run it.
class WhereIsIntent extends Intent {
  const WhereIsIntent();
}

/// C-h a — apropos-command: prompt for a pattern and list matching commands.
class AproposCommandIntent extends Intent {
  const AproposCommandIntent();
}

// --- search (extended) ------------------------------------------------------

/// M-s s — swiper: an ivy/swiper-style live filtered line search, with a
/// preview panel that follows the buffer selection.
class SwiperIntent extends Intent {
  const SwiperIntent();
}

// --- commands (extended) -----------------------------------------------------

/// M-x — execute-extended-command: prompt for a command by name (TAB-
/// completed against the registry) and run it.
class ExecuteExtendedCommandIntent extends Intent {
  const ExecuteExtendedCommandIntent();
}

/// M-! — shell-command: prompt for a shell command, run it, and show its
/// output (a `*Shell Command Output*` buffer, or the echo area when empty).
class ShellCommandIntent extends Intent {
  const ShellCommandIntent();
}

/// M-: — eval-expression: prompt for an elisp form, evaluate it, echo the
/// value.
class EvalExpressionIntent extends Intent {
  const EvalExpressionIntent();
}

/// M-x shell — switch to (creating if needed) an interactive `*shell*`
/// buffer backed by a live process session. No default chord: reached only
/// through M-x (or the config), like `list-buffers`. With a universal
/// argument pending (`C-u M-x shell`), creates the NEXT `*shell*<N>` buffer
/// instead of reusing `*shell*`.
class ShellIntent extends Intent {
  const ShellIntent();
}

/// C-x d — dired: prompt for a directory (defaulting to the open file's
/// directory, or HOME) and list it into a `*dired: <path>*` buffer.
/// Report-only for the default directory (host-owned: only the page knows
/// the open file's path); the listing, navigation and re-listing themselves
/// live in the buffer model/editor once a target directory is chosen.
class DiredIntent extends Intent {
  const DiredIntent();
}

// --- org structure editing ---------------------------------------------------

/// C-c C-t — org-todo: cycle the TODO state of the heading at point
/// (none -> TODO -> DONE -> none). Org-mode only.
class TodoCycleIntent extends Intent {
  const TodoCycleIntent();
}

/// C-c C-c — org-ctrl-c-ctrl-c / org-babel-execute-src-block: execute the
/// source block at point through the org support binary and insert/replace
/// its `#+RESULTS:` block. Report-only (file I/O and process execution live
/// outside the buffer model); org-mode only, guarded by the host.
class BabelExecuteIntent extends Intent {
  const BabelExecuteIntent();
}

// --- windows -----------------------------------------------------------

/// C-x 2 — split-window-below: split the selected window into two, one
/// above the other. Report-only: the buffer model has no notion of windows,
/// so the host owns the split-tree mutation.
class SplitWindowBelowIntent extends Intent {
  const SplitWindowBelowIntent();
}

/// C-x 3 — split-window-right: split the selected window into two,
/// side by side. Report-only, as [SplitWindowBelowIntent].
class SplitWindowRightIntent extends Intent {
  const SplitWindowRightIntent();
}

/// C-x 0 — delete-window: remove the selected window (never the last one).
/// Report-only, as [SplitWindowBelowIntent].
class DeleteWindowIntent extends Intent {
  const DeleteWindowIntent();
}

/// C-x 1 — delete-other-windows: make the selected window the only one.
/// Report-only, as [SplitWindowBelowIntent].
class DeleteOtherWindowsIntent extends Intent {
  const DeleteOtherWindowsIntent();
}

/// C-x o — other-window: move focus to the next window. Report-only, as
/// [SplitWindowBelowIntent].
class OtherWindowIntent extends Intent {
  const OtherWindowIntent();
}

// --- narrowing / imenu --------------------------------------------------

/// C-x n s — narrow-to-region (v1: narrow-to-subtree). Org-mode only:
/// narrows the DISPLAY to the caret's enclosing heading's subtree line
/// range, composing with folds (narrowing only ever ADDS hidden lines, it
/// never removes fold-hidden ones).
class NarrowToSubtreeIntent extends Intent {
  const NarrowToSubtreeIntent();
}

/// C-x n w — widen: clear narrowing and restore the full buffer display.
class WidenIntent extends Intent {
  const WidenIntent();
}

/// M-g i — imenu: prompt (in the completion strip) for a symbol from the
/// current buffer's imenu index (org headings, or per-language definitions)
/// and jump point to it.
class ImenuIntent extends Intent {
  const ImenuIntent();
}
