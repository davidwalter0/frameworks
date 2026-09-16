// Regression: buildAppearanceTheme must apply the PRESET's seed + signature
// background to the envelope theme (rail / bars / sheets), not only its
// semantic palette. Previously only the palette flowed through, so picking
// Nord/Dracula/Catppuccin left the whole app on the default blue seed with no
// background — the preset visibly did nothing outside palette-consuming
// widgets, while kSeedPresets documented '' as "clear → preset seed".
import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAppearanceTheme preset flow', () {
    test('preset seed + background reach the envelope theme (Nord)', () {
      const s = AppearanceSettings(presetName: 'Nord');
      final t = buildAppearanceTheme(s, Brightness.dark);
      // Nord's signature background paints the page…
      expect(t.scaffoldBackgroundColor, const Color(0xFF2E3440));
      // …and its seed (not the default blue) tones the scheme.
      final def =
          buildAppearanceTheme(const AppearanceSettings(), Brightness.dark);
      expect(t.colorScheme.primary, isNot(def.colorScheme.primary));
    });

    test('explicit user overrides still win over the preset', () {
      const s = AppearanceSettings(
        presetName: 'Nord',
        seedHex: 'C62828',
        backgroundHex: '101316',
      );
      final t = buildAppearanceTheme(s, Brightness.dark);
      expect(t.scaffoldBackgroundColor, const Color(0xFF101316));
      final nordOnly = buildAppearanceTheme(
          const AppearanceSettings(presetName: 'Nord'), Brightness.dark);
      expect(t.colorScheme.primary, isNot(nordOnly.colorScheme.primary));
    });

    test('Default preset behaviour is unchanged in light mode', () {
      final t =
          buildAppearanceTheme(const AppearanceSettings(), Brightness.light);
      // No forced background: the scaffold keeps the M3 surface.
      expect(t.scaffoldBackgroundColor, t.colorScheme.surface);
      expect(t.brightness, Brightness.light);
    });

    test('a dark preset background folds the scheme dark even in light mode',
        () {
      final t = buildAppearanceTheme(
          const AppearanceSettings(presetName: 'Catppuccin Mocha'),
          Brightness.light);
      // DeskTheme derives brightness from the page: Mocha's 1E1E2E is dark.
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, const Color(0xFF1E1E2E));
    });
  });
}
