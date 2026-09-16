/// Shared Anthy IME keybinding tooling for desktop_kit — the opt-in bridge
/// between the kana→kanji IME driver (`desktop_kit_anthy.dart`) and the keymap
/// engine (`desktop_kit_keymap.dart`).
///
/// Sibling of `desktop_kit_kana_keymap.dart` (pure script conversion) for the
/// STATEFUL conversion flow. So every app that offers Anthy input binds the
/// conversion commands the same way instead of re-declaring the pattern, this
/// module owns:
/// - the conversion [Intent]s ([ConvertOrNextCandidateIntent],
///   [PreviousCandidateIntent], [CommitConversionIntent],
///   [CancelConversionIntent], [ImeBackspaceIntent]) + stable ids;
/// - [anthyKeymapActions] + [registerAnthyActions] — bindable rows for a
///   (separate) IME keymap surface;
/// - [anthyDefaultBindings] / [anthyDefaultConfig] — the default Space / Enter /
///   Esc / Backspace / Shift+Space IME chords;
/// - [dispatchAnthyIntent] — the single intent→[ImeController] dispatch,
///   returning an [AnthyDispatchResult] the editor acts on; [isAnthyIntentId]
///   for routing.
///
/// **Context-scoped:** these chords only mean their IME command WHILE the
/// controller is active ([ImeState.isActive]); an app matches them then and
/// falls back to the editor keymap otherwise. They are NOT merged into the
/// editor keymap (that would hijack Space / Enter for ordinary typing).
///
/// **Opt-in and Linux-oriented** (Anthy is a Linux IME backend). NOT re-exported
/// from the main `desktop_kit.dart` barrel: the core keymap stays IME-free and
/// non-IME apps pull in nothing. Scope is kana→kanji *conversion*; pure kana
/// *script* conversion (hiragana ⇄ katakana) is `desktop_kit_kana_keymap.dart`.
library;

export 'src/anthy_keymap/anthy_keymap.dart';
