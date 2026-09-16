/// Shared kana keybinding tooling for desktop_kit — the opt-in bridge between
/// the pure kana engine (`desktop_kit_kana.dart`) and the IME-free keymap engine
/// (`desktop_kit_keymap.dart`).
///
/// So every app binds kana the same way instead of re-declaring the pattern,
/// this module owns:
/// - the kana script [Intent]s ([ToggleKanaIntent], [ToKatakanaIntent],
///   [ToHiraganaIntent]) and their stable ids ([kToggleKanaId] etc.);
/// - [kanaKeymapActions] + [registerKanaActions] — bindable [KeymapAction]s the
///   editor offers and a saved [KeymapConfig] round-trips;
/// - [kanaDefaultBindings] + [withKanaDefaults] — the default **Shift-K →
///   toggle kana** binding, mergeable into any config;
/// - [kanaTransform] — the single source of the conversion semantics, called by
///   an app's editor Action on whatever text it scopes to;
/// - [kanaTestEffects] — ready [KeymapTestEffect]s wiring the intents into a
///   [KeymapTestField] for a settings "test your keymap" surface.
///
/// **Opt-in and non-invasive.** This entrypoint is NOT re-exported from the main
/// `desktop_kit.dart` barrel: the core keymap engine stays IME-free and the kana
/// engine stays pure Dart. Import this module only in apps that want kana
/// keybindings (voicelab, word-bank, notekeep); nothing else is affected.
///
/// Scope is kana *script* conversion (hiragana ⇄ katakana). Kana→kanji IME
/// *conversion* (Anthy) is a separate layer that belongs with the Anthy driver.
library;

export 'src/kana_keymap/kana_keymap.dart';
