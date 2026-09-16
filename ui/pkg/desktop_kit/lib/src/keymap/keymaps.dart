// Editor keymaps for the Emacs/CUA engine.
//
// Ported from voicelab and notekeep, stripped of every kana/IME binding.
// The full [MetaKey] enum (alt/ctrl/superKey/esc) from voicelab is retained
// so both notekeep (hardcodes alt) and voicelab (user-configurable) can use
// this package without wrapping.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'editor_intents.dart';
import 'key_chord.dart';
import 'key_chord_sequence.dart';
import 'keymap_config.dart';
import 'keymap_mode.dart';
import 'keymap_registry.dart';

/// Find the [Intent] in [keymap] whose [ShortcutActivator] accepts [event]
/// given the current [keyboard] modifier state, or `null` if none matches.
///
/// Pure and side-effect-free, making it unit-testable: feed it the Emacs/CUA
/// map, a synthesized [KeyDownEvent], and a [HardwareKeyboard] whose pressed
/// modifiers have been set up, and assert which Intent it selects. The live
/// editor uses it with `HardwareKeyboard.instance`.
///
/// Only [KeyDownEvent]s match (chords do not fire on key-up/repeat here).
Intent? matchKeymapIntent(
  Map<ShortcutActivator, Intent> keymap,
  KeyEvent event,
  HardwareKeyboard keyboard,
) {
  if (event is! KeyDownEvent) return null;
  for (final entry in keymap.entries) {
    if (entry.key.accepts(event, keyboard)) return entry.value;
  }
  return null;
}

/// Builds the `Map<ShortcutActivator, Intent>` for a given [KeymapMode].
///
/// CUA leans on Flutter's [DefaultTextEditingShortcuts] for common
/// Ctrl+C/X/V/Z/Y/A and caret motions; we add save, open, kill-ring browser,
/// and help.
///
/// Emacs adds the full motion set (C-a/e/f/b/n/p, M-f/b, M-</M->), kill-ring
/// (C-k/w, M-w, C-y/M-y, Ctrl+Shift+Y browser, Ctrl+Shift+Backspace
/// kill-whole-line), delete (C-d, M-d, M-Backspace), undo (C-//C-_), editing
/// (C-o open-line, C-t transpose-chars, M-SPC just-one-space, M-\
/// delete-horizontal-space, C-l recenter), case (M-u/M-l/M-c), mark
/// (C-SPC), quit (C-g), help (C-h/F1), and the C-x prefix entry. All
/// kana/IME bindings are omitted — voicelab layers those on top.
///
/// The [metaKey] parameter controls which physical modifier carries Emacs
/// M- bindings (default [MetaKey.alt]).
///
/// Pass [overrides] (a user [KeymapConfig], e.g. loaded from the keymap
/// editor's saved JSON) to layer user rebindings on top of the defaults: for
/// every intent the override rebinds, that intent's *default* chords are
/// removed and replaced by the override's chords; intents the override does
/// not mention keep their default chords. [registry] resolves override intent
/// ids to [Intent]s and default [Intent]s back to ids (defaults to
/// [KeymapRegistry.defaults]); pass a host registry when the override binds
/// app-contributed intents (e.g. voicelab' kana intents).
class Keymaps {
  Keymaps._();

  /// Return the keymap for [mode] — the kit defaults for [metaKey], optionally
  /// with a user [overrides] config layered on top (see the class doc).
  static Map<ShortcutActivator, Intent> forMode(
    KeymapMode mode, {
    MetaKey metaKey = MetaKey.alt,
    KeymapConfig? overrides,
    KeymapRegistry? registry,
  }) {
    // Defaults collapse FIRST-writer-wins, which preserves the exact intent
    // [matchKeymapIntent] (a first-match scan) selects today. It only ever has
    // work to do for [MetaKey.ctrl], where an M- binding lands on a chord a C-
    // binding already owns; the control layer is emitted first by [_emacs] so
    // the control binding is the one that survives. See [_collapseByChord].
    final base =
        _collapseByChord(_defaultKeymap(mode, metaKey), keepLast: false);
    if (overrides == null) return base;
    // Only single-stroke override bindings can enter the ShortcutActivator map;
    // Flutter cannot express a multi-stroke sequence, so `C-x C-s`-style
    // overrides are surfaced by [KeymapConfig.sequenceBindings] for the prefix
    // dispatcher instead and are intentionally invisible here (see the
    // KeymapConfig library doc). This keeps runtime behaviour identical for the
    // common single-stroke case.
    final over = overrides.singleStrokeBindings(mode);
    if (over.isEmpty) return base;

    final reg = registry ?? KeymapRegistry.defaults();
    // Intent ids the override rebinds *via a single stroke*. An intent rebound
    // only via a multi-stroke sequence keeps its default single-stroke chord in
    // the live map (no runtime regression) — its sequence rides on
    // sequenceBindings until a later step wires multi-stroke dispatch.
    final overriddenIntentIds = over.values.toSet();

    // Chords the override explicitly UNBINDS ([KeymapConfig.unboundId]
    // tombstones). Honoured here as well as in [KeymapConfig.mergedOnto], so a
    // host that passes a raw DELTA straight to this method still gets the
    // removal instead of quietly getting the default back.
    final tombstoned = <KeyChord>{};
    over.forEach((KeyChordSequence seq, String id) {
      if (id != KeymapConfig.unboundId) return;
      final single = seq.asSingle;
      if (single != null) tombstoned.add(single);
    });

    // Keep default entries whose intent the override does NOT rebind (so a
    // rebound intent's stale default chord is dropped, not left dangling), and
    // which the override has not tombstoned.
    final result = <ShortcutActivator, Intent>{};
    base.forEach((activator, intent) {
      if (activator is SingleActivator &&
          tombstoned.contains(KeyChord.fromActivator(activator))) {
        return;
      }
      final id = reg.idFor(intent);
      if (id == null || !overriddenIntentIds.contains(id)) {
        result[activator] = intent;
      }
    });
    // Apply the override chords (last-writer-wins on any chord collision).
    over.forEach((KeyChordSequence seq, String id) {
      if (id == KeymapConfig.unboundId) return; // a removal, not a binding
      final single = seq.asSingle;
      if (single == null) return; // defensive; singleStrokeBindings guarantees.
      final intent = reg.intentFor(id);
      if (intent != null) result[single.toActivator()] = intent;
    });
    // The override entries were appended, so LAST-writer-wins is what makes an
    // override actually displace a default that survived the id-based filter
    // above. It survives whenever the two are the same *chord* bound to
    // *different* intents — exactly the case a user rebind creates.
    return _collapseByChord(result, keepLast: true);
  }

  /// Collapse [keymap] so at most ONE entry survives per physical chord.
  ///
  /// A `Map` keyed on [ShortcutActivator] cannot do this itself.
  /// [SingleActivator] declares no `operator ==` / `hashCode`, so two
  /// activators describing the same chord are two distinct keys and BOTH
  /// survive (verified: inserting two equal-field `SingleActivator`s yields a
  /// map of length 2). [matchKeymapIntent] is a first-match linear scan, so the
  /// earlier entry wins and the later one is dead code — which is how a user
  /// rebinding an already-bound chord silently did nothing at all.
  ///
  /// Identity is [KeyChord], the package's value-typed chord — the same type
  /// the keymap editor's conflict detection already uses, so "the editor says
  /// these two conflict" and "the runtime treats these two as one" cannot
  /// disagree. It also canonicalises punctuation shift-folding, so a config's
  /// `A-60` (`M-<`) and the default's `SingleActivator(comma, alt, shift)`
  /// resolve to one chord rather than two.
  ///
  /// [keepLast] picks the winner: `false` keeps the FIRST writer (preserving
  /// today's first-match outcome — used for the defaults), `true` keeps the
  /// LAST (so an appended override displaces a default). Entry ORDER always
  /// follows first insertion, so the map's iteration order is stable either
  /// way; only the value at a colliding position changes.
  ///
  /// Non-[SingleActivator] activators have no [KeyChord] form and are passed
  /// through untouched, after the collapsed entries.
  static Map<ShortcutActivator, Intent> _collapseByChord(
    Map<ShortcutActivator, Intent> keymap, {
    required bool keepLast,
  }) {
    final order = <KeyChord>[];
    final winner = <KeyChord, MapEntry<ShortcutActivator, Intent>>{};
    final passthrough = <ShortcutActivator, Intent>{};
    keymap.forEach((activator, intent) {
      if (activator is! SingleActivator) {
        passthrough[activator] = intent;
        return;
      }
      final chord = KeyChord.fromActivator(activator);
      if (!winner.containsKey(chord)) {
        order.add(chord);
        winner[chord] = MapEntry(activator, intent);
      } else if (keepLast) {
        winner[chord] = MapEntry(activator, intent);
      }
    });
    final out = <ShortcutActivator, Intent>{};
    for (final chord in order) {
      final e = winner[chord]!;
      out[e.key] = e.value;
    }
    out.addAll(passthrough);
    return out;
  }

  /// The kit's canonical **multi-stroke** default sequences for [mode], as
  /// `sequence → intent-id`. These are the Emacs `C-x`-prefix bindings that
  /// Flutter's [ShortcutActivator] cannot represent, surfaced so the editor can
  /// show and rebind them:
  ///
  /// | Sequence  | Intent id                 | Command                |
  /// |-----------|---------------------------|------------------------|
  /// | `C-x C-s` | `save`                    | Save buffer            |
  /// | `C-x C-w` | `writeFile`               | Write file (save as)   |
  /// | `C-x C-f` | `openFile`                | Open file              |
  /// | `C-x C-c` | `saveBuffersKillTerminal` | Save buffers and exit  |
  /// | `C-x b`   | `switchBuffer`            | Switch buffer          |
  /// | `C-x C-b` | `listBuffers`             | List buffers           |
  /// | `C-x k`   | `killBuffer`              | Kill buffer            |
  /// | `C-x C-x` | `exchangePointAndMark`    | Exchange point and mark|
  /// | `C-x h`   | `markWholeBuffer`         | Mark whole buffer      |
  /// | `C-x C-p` | `markPage`                | Mark page              |
  ///
  /// The last five restore parity with the deprecated [PrefixDispatcher], whose
  /// hardcoded state machine dispatched `C-x C-x`, `C-x h` and `C-x C-p` while
  /// this map did not — so a host migrating off it silently lost them.
  ///
  /// **Runtime dispatch for these still comes from [PrefixDispatcher]** — this
  /// map feeds the editor and [KeymapConfig.fromDefaults] only. A sequence
  /// matcher that consumes [KeymapConfig.sequenceBindings] at runtime arrives in
  /// a later step; until then a *rebind* of one of these rows is persisted and
  /// shown but does not change what the running editor does. (Emacs mode only;
  /// CUA has no `C-x` prefix, so its map is empty.)
  static Map<KeyChordSequence, String> defaultSequenceBindings(
    KeymapMode mode,
  ) {
    if (mode != KeymapMode.emacs) return const <KeyChordSequence, String>{};
    KeyChord cChord(LogicalKeyboardKey k) =>
        KeyChord(keyId: k.keyId, control: true);
    KeyChord bareChord(LogicalKeyboardKey k) => KeyChord(keyId: k.keyId);
    final cx = cChord(LogicalKeyboardKey.keyX);
    final cc = cChord(LogicalKeyboardKey.keyC);
    return <KeyChordSequence, String>{
      // C-x C-s — save buffer.
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyS)]): 'save',
      // C-x C-w — write-file ("save as").
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyW)]):
          'writeFile',
      // C-x C-f — open file.
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyF)]):
          'openFile',
      // C-x C-c — save-buffers-kill-terminal. The contract is PROMPT, never
      // force-save; see [SaveBuffersKillTerminalIntent].
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyC)]):
          'saveBuffersKillTerminal',
      // C-x b — switch buffer.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.keyB)]):
          'switchBuffer',
      // C-x C-b — list-buffers.
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyB)]):
          'listBuffers',
      // C-x k — kill buffer.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.keyK)]):
          'killBuffer',
      // C-x C-x — exchange-point-and-mark (PrefixDispatcher parity).
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyX)]):
          'exchangePointAndMark',
      // C-x h — mark-whole-buffer (PrefixDispatcher parity).
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.keyH)]):
          'markWholeBuffer',
      // C-x C-p — mark-page (PrefixDispatcher parity).
      KeyChordSequence(<KeyChord>[cx, cChord(LogicalKeyboardKey.keyP)]):
          'markPage',
      // C-c C-t — org-todo: cycle the TODO state at point (org-mode only;
      // the editor guards the actual mutation on [orgMode]).
      KeyChordSequence(<KeyChord>[cc, cChord(LogicalKeyboardKey.keyT)]):
          'todoCycle',
      // C-c C-c — org-ctrl-c-ctrl-c: execute the source block at point
      // (org-mode only; report-only, so the host guards it and does the
      // actual process execution / buffer edit).
      KeyChordSequence(<KeyChord>[cc, cChord(LogicalKeyboardKey.keyC)]):
          'babelExecute',
      // C-x 2 — split-window-below.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.digit2)]):
          'splitWindowBelow',
      // C-x 3 — split-window-right.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.digit3)]):
          'splitWindowRight',
      // C-x 0 — delete-window.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.digit0)]):
          'deleteWindow',
      // C-x 1 — delete-other-windows.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.digit1)]):
          'deleteOtherWindows',
      // C-x o — other-window.
      KeyChordSequence(<KeyChord>[cx, bareChord(LogicalKeyboardKey.keyO)]):
          'otherWindow',
      // C-x n s — narrow-to-subtree.
      KeyChordSequence(<KeyChord>[
        cx,
        bareChord(LogicalKeyboardKey.keyN),
        bareChord(LogicalKeyboardKey.keyS),
      ]): 'narrowToSubtree',
      // C-x n w — widen.
      KeyChordSequence(<KeyChord>[
        cx,
        bareChord(LogicalKeyboardKey.keyN),
        bareChord(LogicalKeyboardKey.keyW),
      ]): 'widen',
      // M-g i — imenu.
      KeyChordSequence(<KeyChord>[
        KeyChord(keyId: LogicalKeyboardKey.keyG.keyId, alt: true),
        bareChord(LogicalKeyboardKey.keyI),
      ]): 'imenu',
    };
  }

  static Map<ShortcutActivator, Intent> _defaultKeymap(
    KeymapMode mode,
    MetaKey metaKey,
  ) {
    return switch (mode) {
      KeymapMode.cua => _cua(),
      KeymapMode.emacs => _emacs(metaKey),
    };
  }

  static Map<ShortcutActivator, Intent> _cua() {
    return <ShortcutActivator, Intent>{
      // Ctrl+S — save.
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          const SaveBufferIntent(),
      // Ctrl+O — open / find file.
      const SingleActivator(LogicalKeyboardKey.keyO, control: true):
          const OpenFileIntent(),
      // Ctrl+Shift+Y — kill-ring browser (Ctrl+Y alone is CUA redo).
      const SingleActivator(
        LogicalKeyboardKey.keyY,
        control: true,
        shift: true,
      ): const BrowseKillRingIntent(),
      // F1 — keyboard-shortcut help.
      const SingleActivator(LogicalKeyboardKey.f1): const HelpIntent(),
    };
  }

  /// Build a [SingleActivator] for an Emacs M- binding using the resolved
  /// [meta]. For [MetaKey.esc], resolves to alt by design (see [MetaKey.esc]).
  static SingleActivator _meta(LogicalKeyboardKey key, MetaKey meta) =>
      switch (meta) {
        MetaKey.ctrl => SingleActivator(key, control: true),
        MetaKey.superKey => SingleActivator(key, meta: true),
        MetaKey.alt || MetaKey.esc => SingleActivator(key, alt: true),
      };

  /// Build a [SingleActivator] for an Emacs M-Shift- binding (e.g. M-< and
  /// M->). The shift modifier is held alongside the meta modifier.
  static SingleActivator _metaShift(LogicalKeyboardKey key, MetaKey meta) =>
      switch (meta) {
        MetaKey.ctrl => SingleActivator(key, control: true, shift: true),
        MetaKey.superKey => SingleActivator(key, meta: true, shift: true),
        MetaKey.alt ||
        MetaKey.esc =>
          SingleActivator(key, alt: true, shift: true),
      };

  /// The Emacs map, emitted as TWO layers: every `C-` binding first, then every
  /// `M-` binding.
  ///
  /// The split is not cosmetic. [MetaKey.ctrl] resolves M- onto Control, which
  /// lands ten M- bindings on chords a C- binding already owns (C-f, C-b, C-w,
  /// C-d, C-y, C-t, C-SPC, C-l, C-u, C-v). Emitting the control layer first and
  /// collapsing first-writer-wins makes the **C- binding win every one of
  /// them** — which is what GNU Emacs defines on that physical chord. Before
  /// the split the winner was whichever line happened to be written first, and
  /// two of the ten (C-SPC and C-u) went to the M- binding by accident.
  static Map<ShortcutActivator, Intent> _emacs(MetaKey meta) {
    return <ShortcutActivator, Intent>{
      // ---- control layer ---------------------------------------------------
      // Motions.
      const SingleActivator(LogicalKeyboardKey.keyA, control: true):
          const MoveLineStartIntent(),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true):
          const MoveLineEndIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true):
          const MoveForwardCharIntent(),
      const SingleActivator(LogicalKeyboardKey.keyB, control: true):
          const MoveBackwardCharIntent(),
      const SingleActivator(LogicalKeyboardKey.keyN, control: true):
          const MoveNextLineIntent(),
      const SingleActivator(LogicalKeyboardKey.keyP, control: true):
          const MovePreviousLineIntent(),

      // Kill ring.
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          const KillLineIntent(),
      const SingleActivator(
        LogicalKeyboardKey.backspace,
        control: true,
        shift: true,
      ): const KillWholeLineIntent(),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          const KillRegionIntent(),
      const SingleActivator(LogicalKeyboardKey.keyD, control: true):
          const DeleteCharIntent(),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true):
          const YankIntent(),
      // Ctrl+Shift+Y — kill-ring browser (same chord as CUA).
      const SingleActivator(
        LogicalKeyboardKey.keyY,
        control: true,
        shift: true,
      ): const BrowseKillRingIntent(),

      // Undo: C-/ (and C-_, the other Emacs undo binding).
      const SingleActivator(LogicalKeyboardKey.slash, control: true):
          const EditorUndoIntent(),
      const SingleActivator(LogicalKeyboardKey.underscore, control: true):
          const EditorUndoIntent(),

      // Editing.
      const SingleActivator(LogicalKeyboardKey.keyO, control: true):
          const OpenLineIntent(),
      const SingleActivator(LogicalKeyboardKey.keyT, control: true):
          const TransposeCharsIntent(),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true):
          const RecenterIntent(),

      // Terminal / whitespace translations — the historical tty control codes
      // (C-i = HT, C-j = LF, C-m = CR). These physical chords are otherwise
      // unbound in this map, so binding them is additive (RET/TAB are left to
      // the host's own handling and are not rebound here).
      const SingleActivator(LogicalKeyboardKey.keyI, control: true):
          const InsertTabIntent(),
      const SingleActivator(LogicalKeyboardKey.keyJ, control: true):
          const NewlineIntent(),
      const SingleActivator(LogicalKeyboardKey.keyM, control: true):
          const NewlineIntent(),

      // Mark.
      const SingleActivator(LogicalKeyboardKey.space, control: true):
          const SetMarkIntent(),

      // Quit (C-g, keyboard-quit).
      const SingleActivator(LogicalKeyboardKey.keyG, control: true):
          const KeyboardQuitIntent(),

      // Help (C-h / F1).
      const SingleActivator(LogicalKeyboardKey.keyH, control: true):
          const HelpIntent(),
      const SingleActivator(LogicalKeyboardKey.f1): const HelpIntent(),

      // Prefix entry. C-x is a prefix and NOTHING else — the second stroke is
      // resolved by [SequenceMatcher] against [defaultSequenceBindings].
      const SingleActivator(LogicalKeyboardKey.keyX, control: true):
          const PrefixCtrlXIntent(),

      // Search. GNU Emacs: C-s = isearch-forward, C-r = isearch-backward.
      // Saving is C-x C-s, and ONLY C-x C-s — a standalone C-s → save is a CUA
      // convention that has no place in an Emacs map (see [_cua], which keeps
      // it, correctly, for CUA).
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          const IsearchForwardIntent(),
      const SingleActivator(LogicalKeyboardKey.keyR, control: true):
          const IsearchBackwardIntent(),

      // Editing / scrolling (extended).
      const SingleActivator(LogicalKeyboardKey.keyU, control: true):
          const UniversalArgumentIntent(),
      const SingleActivator(LogicalKeyboardKey.keyV, control: true):
          const ScrollUpIntent(),

      // ---- meta layer ------------------------------------------------------
      // Emitted second on purpose: under [MetaKey.ctrl] these collide with the
      // control layer above, and the control binding must win. See the doc.
      _meta(LogicalKeyboardKey.keyF, meta): const MoveForwardWordIntent(),
      _meta(LogicalKeyboardKey.keyB, meta): const MoveBackwardWordIntent(),
      // M-< (Shift+Comma) = beginning-of-buffer
      _metaShift(LogicalKeyboardKey.comma, meta): const MoveBufferStartIntent(),
      // M-> (Shift+Period) = end-of-buffer
      _metaShift(LogicalKeyboardKey.period, meta): const MoveBufferEndIntent(),
      _meta(LogicalKeyboardKey.keyW, meta): const CopyRegionIntent(),
      _meta(LogicalKeyboardKey.keyD, meta): const DeleteWordForwardIntent(),
      _meta(LogicalKeyboardKey.backspace, meta):
          const DeleteWordBackwardIntent(),
      _meta(LogicalKeyboardKey.keyY, meta): const YankPopIntent(),
      _meta(LogicalKeyboardKey.space, meta): const JustOneSpaceIntent(),
      _meta(LogicalKeyboardKey.backslash, meta):
          const DeleteHorizontalSpaceIntent(),
      // Case.
      _meta(LogicalKeyboardKey.keyU, meta): const UpcaseWordIntent(),
      _meta(LogicalKeyboardKey.keyL, meta): const DowncaseWordIntent(),
      _meta(LogicalKeyboardKey.keyC, meta): const CapitalizeWordIntent(),
      // Editing / scrolling (extended). Everything else in the intent set
      // (M-x, M-%, M-g g, C-h b, C-x r s, C-x (, …) is left for the config to
      // bind rather than claimed by default.
      _meta(LogicalKeyboardKey.keyV, meta): const ScrollDownIntent(),
      _meta(LogicalKeyboardKey.keyT, meta): const TransposeWordsIntent(),
      _meta(LogicalKeyboardKey.keyZ, meta): const ZapToCharIntent(),
      _meta(LogicalKeyboardKey.semicolon, meta): const CommentDwimIntent(),
    };
  }
}
