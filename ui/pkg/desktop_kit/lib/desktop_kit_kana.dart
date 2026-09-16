/// Pure kana/romaji conversion engine for desktop_kit.
///
/// Includes:
/// - [Kana] — Hepburn romaji ↔ hiragana/katakana conversion tables and pure
///   converters ([Kana.romajiToHiragana], [Kana.toRomaji],
///   [Kana.hiraganaToKatakana], [Kana.katakanaToHiragana]), plus the editor
///   toggles [Kana.toggleKana] (reversible per-character katakana⇄hiragana) and
///   [Kana.toggleRomajiKana] (romaji⇄kana, the C-\ input toggle)
/// - [RomajiInputBuffer] / [RomajiResult] — incremental (eager, per-mora)
///   romaji→hiragana state machine for live keystroke-by-keystroke input
///
/// Pure Dart, no Flutter dependency: headlessly testable, IME-free. Apps
/// layer their own IME composing guard, Intent subclasses, and keymap
/// bindings on top (see voicelab) — this package carries only the engine.
library;

export 'src/kana/kana.dart';
export 'src/kana/romaji_input_buffer.dart';
