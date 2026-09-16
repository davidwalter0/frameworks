import 'package:desktop_kit/desktop_kit.dart';
import 'package:desktop_kit/desktop_kit_kana_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeyChordSequence _shiftK() => KeyChordSequence.single(
      KeyChord(keyId: LogicalKeyboardKey.keyK.keyId, shift: true),
    );

void main() {
  test('registerKanaActions adds the kana actions, keeping kit built-ins', () {
    final registry = KeymapRegistry.defaults();
    registerKanaActions(registry);
    for (final String id in <String>[
      kToggleKanaId,
      kToKatakanaId,
      kToHiraganaId,
    ]) {
      expect(registry.contains(id), isTrue, reason: id);
      expect(registry.action(id)?.group, 'Kana', reason: id);
    }
    expect(registry.contains('killLine'), isTrue); // kit built-in survives
  });

  test('withKanaDefaults seeds Shift-K→toggle in every mode', () {
    final registry = KeymapRegistry.defaults();
    registerKanaActions(registry);
    final base = KeymapConfig.fromDefaults(registry);
    final merged = withKanaDefaults(base);
    for (final KeymapMode mode in KeymapMode.values) {
      expect(merged.bindingsFor(mode)[_shiftK()], kToggleKanaId,
          reason: mode.name);
      // existing kit bindings are preserved (only added to)
      expect(merged.bindingsFor(mode).length,
          greaterThanOrEqualTo(base.bindingsFor(mode).length));
    }
  });

  test('withKanaDefaults does not clobber an existing Shift-K binding', () {
    final registry = KeymapRegistry.defaults();
    registerKanaActions(registry);
    final base = KeymapConfig.fromDefaults(registry);
    final preBound = base.withMode(
      KeymapMode.emacs,
      <KeyChordSequence, String>{
        ...base.bindingsFor(KeymapMode.emacs),
        _shiftK(): 'killLine',
      },
    );
    final merged = withKanaDefaults(preBound);
    expect(merged.bindingsFor(KeymapMode.emacs)[_shiftK()], 'killLine');
  });

  group('kanaTransform', () {
    test('toggle flips each kana reversibly', () {
      expect(kanaTransform(kToggleKanaId, 'きょうカ'), 'キョウか');
    });
    test('directional conversions', () {
      expect(kanaTransform(kToKatakanaId, 'きょう'), 'キョウ');
      expect(kanaTransform(kToHiraganaId, 'キョウ'), 'きょう');
    });
    test('romaji ↔ kana toggle both ways', () {
      expect(kanaTransform(kToggleRomajiKanaId, 'nihon'), 'にほん');
      expect(kanaTransform(kToggleRomajiKanaId, 'にほん'), 'nihon');
    });
    test('unknown id returns null', () {
      expect(kanaTransform('nope', 'x'), isNull);
    });
  });

  test('withKanaDefaults seeds C-\\ → toggle romaji↔kana', () {
    final registry = KeymapRegistry.defaults();
    registerKanaActions(registry);
    final merged = withKanaDefaults(KeymapConfig.fromDefaults(registry));
    final ctrlBackslash = KeyChordSequence.single(
      KeyChord(keyId: LogicalKeyboardKey.backslash.keyId, control: true),
    );
    for (final KeymapMode mode in KeymapMode.values) {
      expect(merged.bindingsFor(mode)[ctrlBackslash], kToggleRomajiKanaId,
          reason: mode.name);
    }
  });

  test('kanaTestEffects wires an effect per kana action', () {
    final effects = kanaTestEffects();
    expect(effects.keys.toSet(), <String>{
      kToggleKanaId,
      kToKatakanaId,
      kToHiraganaId,
      kToggleRomajiKanaId,
    });
    final result = effects[kToggleKanaId]!('あ', 1);
    expect(result?.text, 'ア');
    expect(result?.caret, 1);
  });
}
