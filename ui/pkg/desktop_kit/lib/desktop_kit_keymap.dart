/// Emacs/CUA keymap engine for desktop_kit.
///
/// Includes:
/// - [KeymapMode] (cua / emacs) and [MetaKey] (alt / ctrl / superKey / esc)
/// - The full [Intent] set ([MoveLineStartIntent], [KillLineIntent], etc.)
/// - [Keymaps.forMode] factory (with optional user [KeymapConfig] overrides)
///   and [matchKeymapIntent] pure matcher
/// - [KeymapEditor] — controlled, per-mode rebinding UI over a [KeymapRegistry]
///   of [KeymapAction]s; [KeyChord] serialisable chord; [KeymapConfig] JSON
///   round-trip and reset-to-defaults
/// - [KeymapConfig.delta] / [KeymapConfig.mergedOnto] — layered persistence:
///   save only what DIFFERS from the shipped defaults, load as
///   `defaults + delta`, so a corrected default reaches every user instead of
///   being frozen out by a whole-config snapshot. [KeymapConfig.upgraded] is
///   the one-shot, closed-ended transition for files already written as
///   snapshots
/// - [SequenceMatcher] — config-driven multi-stroke dispatch trie; supersedes
///   the hardcoded [PrefixDispatcher] (which is now @Deprecated)
/// - [KeymapTestField] — an editable probe box that dispatches a [KeymapConfig]
///   live (single-stroke + [SequenceMatcher] sequences) so a rebind can be
///   verified to fire without wiring the editor into a real app editor
/// - [PrefixDispatcher] — deprecated C-x two-stroke state machine; use
///   [SequenceMatcher] for new code
/// - [KillRing] with append-merge, yank, and yank-pop semantics
/// - Data-driven [showKeymapHelp] dialog ([KeymapHelpGroup] / [KeymapBinding])
/// - [XiGlyph] — the ξ glyph following the ambient [IconTheme]
/// - [MarkState] / [Region] — Emacs mark-ring state (set-mark, exchange-point-
///   and-mark, region tracking) backing C-w / M-w / mark commands
/// - [TextMotions] — pure text-motion + kill-span primitives (word/line/char
///   motion, `killLineSpan`, `deleteWordForwardSpan`, etc.)
///
/// IME-free by design: kana/romaji bindings are NOT included — apps layer
/// those on top via their own Intent subclasses. The kana/romaji *conversion
/// engine* lives in the separate `desktop_kit_kana.dart` entrypoint, and the
/// optional Anthy kana→kanji IME *driver* (subprocess client + headless
/// conversion controller, no widgets) lives in the separate, opt-in
/// `desktop_kit_anthy.dart` entrypoint. This core keymap module never depends
/// on either — both are additive modules apps opt into.
library;

export 'src/keymap/editor_intents.dart';
export 'src/keymap/key_chord.dart';
export 'src/keymap/key_chord_sequence.dart';
export 'src/keymap/keymap_config.dart';
export 'src/keymap/keymap_editor.dart';
export 'src/keymap/keymap_editor_surface.dart';
export 'src/keymap/keymap_help.dart';
export 'src/keymap/keymap_mode.dart';
export 'src/keymap/keymap_registry.dart';
export 'src/keymap/keymap_test_field.dart';
export 'src/keymap/keymaps.dart';
export 'src/keymap/kill_ring.dart';
export 'src/keymap/mark_state.dart';
export 'src/keymap/prefix_dispatcher.dart';
export 'src/keymap/sequence_matcher.dart';
export 'src/keymap/text_motions.dart';
export 'src/keymap/xi_glyph.dart';
