import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeskTheme.hexToColor', () {
    test('parses with and without a leading #', () {
      expect(DeskTheme.hexToColor('#FF0000'), const Color(0xFFFF0000));
      expect(DeskTheme.hexToColor('00FF00'), const Color(0xFF00FF00));
    });
    test('empty or malformed → null', () {
      expect(DeskTheme.hexToColor(''), isNull);
      expect(DeskTheme.hexToColor('xyz'), isNull);
      expect(DeskTheme.hexToColor('12345'), isNull); // wrong length
    });
  });

  group('DeskTheme builds', () {
    test('preset palette is attached and readable as the extension', () {
      final t = DeskTheme.dark(palette: DeskPalette.dracula);
      expect(t.extension<DeskPalette>(), DeskPalette.dracula);
      expect(t.brightness, Brightness.dark);
    });

    test('the app may pass its own palette instance (stored verbatim)', () {
      final t = DeskTheme.light(palette: DeskPalette.nord);
      expect(t.extension<DeskPalette>(), DeskPalette.nord);
    });

    test('illegible fg override → replaced by contrastingOn(effBg)', () {
      // White text on a white background must NOT be applied verbatim; the
      // guard substitutes a contrasting colour (black) = contrastingOn(white).
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: 'FFFFFF',
        foregroundHex: 'FFFFFF',
      );
      expect(
          t.textTheme.bodyLarge?.color, contrastingOn(const Color(0xFFFFFFFF)));
      expect(t.textTheme.bodyLarge?.color, Colors.black);
    });

    test('a legible foreground is honoured', () {
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: '000000',
        foregroundHex: 'FFFFFF',
      );
      expect(t.textTheme.bodyLarge?.color, const Color(0xFFFFFFFF));
    });

    test('no override → M3 ColorScheme text colours untouched', () {
      final t = DeskTheme.light(palette: DeskPalette.standard);
      // The builder returns the base ThemeData unchanged (no foreground paint).
      final base = ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
      );
      expect(t.textTheme.bodyLarge?.color, base.textTheme.bodyLarge?.color);
    });

    test('a background-only override still derives a contrasting fg', () {
      // Only the background was overridden → foreground is derived even with no
      // foregroundHex, so text never melts into the new background.
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: '000000',
      );
      expect(t.textTheme.bodyLarge?.color, Colors.white);
    });
  });

  group('DeskTheme surface-family fold (background override)', () {
    // A pale background (light grey) with a derived dark foreground to exercise
    // the surface fold path.
    const String paleBg = 'F0F0F0'; // nearly white → contrastingOn = black
    const Color paleBgColor = Color(0xFFF0F0F0);

    test('colorScheme.surface equals the override colour', () {
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: paleBg,
      );
      expect(t.colorScheme.surface, paleBgColor);
    });

    test('onSurface is legible on surface (Cards)', () {
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: paleBg,
      );
      expect(
          isLegibleOn(t.colorScheme.onSurface, t.colorScheme.surface), isTrue);
    });

    test('onSurface is legible on surfaceContainerHigh (Dialogs/Sheets)', () {
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: paleBg,
      );
      expect(
        isLegibleOn(
          t.colorScheme.onSurface,
          t.colorScheme.surfaceContainerHigh,
        ),
        isTrue,
      );
    });

    test('no override → M3 surface is unchanged (fold not applied)', () {
      final t = DeskTheme.light(palette: DeskPalette.standard);
      final m3 = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1565C0),
        brightness: Brightness.light,
      );
      expect(t.colorScheme.surface, m3.surface);
    });
  });

  group('DeskTheme accent legibility (scheme brightness follows the page)', () {
    // Nord: a LIGHT seed (#81A1C1) paired with a DARK page (#2E3440). The app
    // requests light mode, but the page it paints is dark. The scheme brightness
    // must follow the PAGE — otherwise `primary` (section headers, links,
    // selected chips) is toned for a light background and is illegible on the
    // dark page: the "contrast insufficient" report.
    const String nordSeed = '81A1C1';
    const String nordBg = '2E3440';
    const Color nordBgColor = Color(0xFF2E3440);

    test('a dark background override tones the whole ThemeData dark', () {
      final t = DeskTheme.light(
        palette: DeskPalette.nord,
        seedColorHex: nordSeed,
        backgroundOverride: nordBg,
      );
      expect(t.brightness, Brightness.dark);
    });

    test('primary contrast improves and clears the WCAG floor on the dark page',
        () {
      // Pre-fix: fromSeed(seed, LIGHT).primary — a dark-toned blue meant for a
      // light background, which failed on the dark page.
      final oldPrimary = ColorScheme.fromSeed(
        seedColor: const Color(0xFF81A1C1),
        brightness: Brightness.light,
      ).primary;
      final t = DeskTheme.light(
        palette: DeskPalette.nord,
        seedColorHex: nordSeed,
        backgroundOverride: nordBg,
      );
      final oldContrast = contrastRatio(oldPrimary, nordBgColor);
      final newContrast =
          contrastRatio(t.colorScheme.primary, t.colorScheme.surface);
      expect(newContrast, greaterThan(oldContrast),
          reason:
              'deriving dark brightness raises primary contrast on the page');
      expect(isLegibleOn(t.colorScheme.primary, t.colorScheme.surface), isTrue,
          reason: 'primary must clear the WCAG floor on the dark page');
    });

    test('a light background override keeps the scheme light and legible', () {
      final t = DeskTheme.dark(
        palette: DeskPalette.standard,
        backgroundOverride: 'FAFAFA',
      );
      expect(t.brightness, Brightness.light);
      expect(isLegibleOn(t.colorScheme.primary, t.colorScheme.surface), isTrue);
    });
  });
}
