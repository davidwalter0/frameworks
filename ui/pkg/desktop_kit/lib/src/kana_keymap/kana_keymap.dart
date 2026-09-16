// Shared kana keybinding tooling — the bridge between the kit's pure kana engine
// and its IME-free keymap engine.
//
// WHY THIS EXISTS: every app in the family (voicelab, word-bank, notekeep) wants
// the same kana script commands bound the same way — "toggle katakana ↔
// hiragana", "convert to katakana", "convert to hiragana". Without a shared home
// each app re-declares the Intents, re-registers the KeymapActions, re-seeds the
// default chords, and re-wires the transforms. This module owns that pattern
// once so an app's whole kana-keymap integration is:
//
//   final registry = KeymapRegistry.defaults();
//   registerKanaActions(registry);                       // editor offers them
//   var config = withKanaDefaults(KeymapConfig.fromDefaults(registry));
//   // in the editor's Action: controller.replaceSelection(
//   //     kanaTransform(intentId, selectedText)!)        // shared transform
//   // in a KeymapTestField (settings): effects: kanaTestEffects()
//
// LAYERING: this is a Flutter-dependent bridge that depends on BOTH
// `desktop_kit_kana.dart` (pure [Kana] transforms) and `desktop_kit_keymap.dart`
// ([Intent] / [KeymapAction] / [KeyChord]). It is a SEPARATE, opt-in entrypoint
// — the core keymap engine stays IME-free (never imports this) and the kana
// engine stays pure Dart (never imports this). Apps that want kana keybindings
// import `desktop_kit_kana_keymap.dart`; everyone else is unaffected.
//
// SCOPE: kana *script* conversion (hiragana ⇄ katakana), which is pure and
// [Kana]-backed. Kana→kanji IME *conversion* (Anthy: convert/candidate cycling)
// is a separate layer that belongs with the Anthy driver, not here.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../kana/kana.dart';
import '../keymap/key_chord.dart';
import '../keymap/key_chord_sequence.dart';
import '../keymap/keymap_config.dart';
import '../keymap/keymap_mode.dart';
import '../keymap/keymap_registry.dart';
import '../keymap/keymap_test_field.dart';

// --- Stable intent ids (persisted in KeymapConfig JSON — do not rename) -------

/// Toggle each kana between hiragana and katakana (reversible). See
/// [Kana.toggleKana].
const String kToggleKanaId = 'toggleKana';

/// Convert kana to katakana. See [Kana.hiraganaToKatakana].
const String kToKatakanaId = 'toKatakana';

/// Convert kana to hiragana. See [Kana.katakanaToHiragana].
const String kToHiraganaId = 'toHiragana';

/// Toggle between romaji and kana (`nihon` ⇄ `にほん`). See
/// [Kana.toggleRomajiKana].
const String kToggleRomajiKanaId = 'toggleRomajiKana';

// --- Marker intents (apps bind Actions to these; transforms are shared) -------

/// Toggle the kana script (katakana ↔ hiragana) of the target text.
class ToggleKanaIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ToggleKanaIntent();
}

/// Convert the target text's kana to katakana.
class ToKatakanaIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ToKatakanaIntent();
}

/// Convert the target text's kana to hiragana.
class ToHiraganaIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ToHiraganaIntent();
}

/// Toggle the target text between romaji and kana.
class ToggleRomajiKanaIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ToggleRomajiKanaIntent();
}

// --- Registry actions ---------------------------------------------------------

/// The bindable kana actions, in editor display order. Register them into any
/// [KeymapRegistry] with [registerKanaActions] so they appear in the editor and
/// round-trip through a saved [KeymapConfig].
const List<KeymapAction> kanaKeymapActions = <KeymapAction>[
  KeymapAction(
    id: kToggleKanaId,
    label: 'Toggle kana (katakana ↔ hiragana)',
    group: 'Kana',
    factory: ToggleKanaIntent.new,
  ),
  KeymapAction(
    id: kToKatakanaId,
    label: 'Convert to katakana',
    group: 'Kana',
    factory: ToKatakanaIntent.new,
  ),
  KeymapAction(
    id: kToHiraganaId,
    label: 'Convert to hiragana',
    group: 'Kana',
    factory: ToHiraganaIntent.new,
  ),
  KeymapAction(
    id: kToggleRomajiKanaId,
    label: 'Toggle romaji ↔ kana',
    group: 'Kana',
    factory: ToggleRomajiKanaIntent.new,
  ),
];

/// Register every [kanaKeymapActions] entry into [registry] (re-registering an
/// id replaces it, preserving order). Call after [KeymapRegistry.defaults] so
/// the kana rows join the kit's built-ins in one editor.
void registerKanaActions(KeymapRegistry registry) {
  for (final KeymapAction action in kanaKeymapActions) {
    registry.register(action);
  }
}

// --- Default bindings ---------------------------------------------------------

/// The default kana keybindings as a mergeable `chord → intent-id` map:
/// **Shift-K → toggle kana** and **C-\ → toggle romaji ↔ kana** (the Emacs
/// `toggle-input-method` chord). The directional conversions are offered unbound
/// for the user to assign.
Map<KeyChordSequence, String> kanaDefaultBindings() =>
    <KeyChordSequence, String>{
      KeyChordSequence.single(
        KeyChord(keyId: LogicalKeyboardKey.keyK.keyId, shift: true),
      ): kToggleKanaId,
      KeyChordSequence.single(
        KeyChord(keyId: LogicalKeyboardKey.backslash.keyId, control: true),
      ): kToggleRomajiKanaId,
    };

/// Return a copy of [config] with [kanaDefaultBindings] merged into each of
/// [modes] (default: every mode), leaving existing bindings intact. Idempotent.
KeymapConfig withKanaDefaults(
  KeymapConfig config, {
  Iterable<KeymapMode> modes = KeymapMode.values,
}) {
  KeymapConfig out = config;
  final Map<KeyChordSequence, String> defaults = kanaDefaultBindings();
  for (final KeymapMode mode in modes) {
    final Map<KeyChordSequence, String> merged =
        Map<KeyChordSequence, String>.from(out.bindingsFor(mode));
    // putIfAbsent, not addAll: a default never clobbers a chord the user already
    // bound (to a kana action or anything else).
    defaults.forEach((KeyChordSequence chord, String id) {
      merged.putIfAbsent(chord, () => id);
    });
    out = out.withMode(mode, merged);
  }
  return out;
}

// --- Shared transforms --------------------------------------------------------

/// The pure whole-[text] transform for a kana intent [id], or `null` if [id] is
/// not a kana intent. An app's editor Action calls this on whatever text it
/// scopes to (region / current word / buffer — the app's choice); the probe
/// effects use it too. Keeps the single source of the conversion semantics here.
String? kanaTransform(String id, String text) {
  switch (id) {
    case kToggleKanaId:
      return Kana.toggleKana(text);
    case kToKatakanaId:
      return Kana.hiraganaToKatakana(text);
    case kToHiraganaId:
      return Kana.katakanaToHiragana(text);
    case kToggleRomajiKanaId:
      return Kana.toggleRomajiKana(text);
    default:
      return null;
  }
}

/// [KeymapTestField.effects] for the kana intents — each rewrites the whole
/// buffer via [kanaTransform] (a clear, reversible demonstration in a probe; a
/// real editor scopes to the region / current word instead).
Map<String, KeymapTestEffect> kanaTestEffects() {
  final Map<String, KeymapTestEffect> out = <String, KeymapTestEffect>{};
  for (final KeymapAction action in kanaKeymapActions) {
    out[action.id] = (String text, int caret) {
      final String? next = kanaTransform(action.id, text);
      return next == null ? null : (text: next, caret: caret);
    };
  }
  return out;
}
