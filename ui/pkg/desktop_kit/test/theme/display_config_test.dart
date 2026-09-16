import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DisplayConfig defaults + accessors', () {
    test('default font strings mean "inherit" (null families)', () {
      const c = DisplayConfig();
      expect(c.appFont, '');
      expect(c.monoFont, '');
      expect(c.appFontFamily, isNull);
      expect(c.baseSize, 13);
      expect(c.weight, 400);
      expect(c.uiScale, 1.0);
    });

    test('a non-empty appFont surfaces as the family', () {
      const c = DisplayConfig(appFont: 'Cantarell');
      expect(c.appFontFamily, 'Cantarell');
    });
  });

  group('DisplayConfig.copyWith', () {
    test('replaces only the given fields', () {
      const base = DisplayConfig(appFont: 'A', monoFont: 'M', baseSize: 13);
      final c = base.copyWith(baseSize: 16, weight: 700);
      expect(c.appFont, 'A');
      expect(c.monoFont, 'M');
      expect(c.baseSize, 16);
      expect(c.weight, 700);
      expect(c.uiScale, 1.0); // untouched, still the default
    });

    test('replaces uiScale when given, keeping the rest', () {
      const base = DisplayConfig(appFont: 'A', baseSize: 13);
      final c = base.copyWith(uiScale: 1.25);
      expect(c.appFont, 'A');
      expect(c.baseSize, 13);
      expect(c.uiScale, 1.25);
    });
  });

  group('DisplayConfig.fontWeight mapping', () {
    test('maps the weight axis to the nearest Material FontWeight', () {
      expect(const DisplayConfig(weight: 100).fontWeight, FontWeight.w100);
      expect(const DisplayConfig(weight: 400).fontWeight, FontWeight.w400);
      expect(const DisplayConfig(weight: 700).fontWeight, FontWeight.w700);
      expect(const DisplayConfig(weight: 900).fontWeight, FontWeight.w900);
    });
    test('clamps out-of-range weights into the FontWeight table', () {
      expect(const DisplayConfig(weight: 0).fontWeight, FontWeight.w100);
      expect(const DisplayConfig(weight: 5000).fontWeight, FontWeight.w900);
    });
  });

  group('DisplayConfig text styles', () {
    test('bodyStyle carries the app font, size, weight + wght variation', () {
      const c = DisplayConfig(appFont: 'Cantarell', baseSize: 15, weight: 600);
      final s = c.bodyStyle;
      expect(s.fontFamily, 'Cantarell');
      expect(s.fontSize, 15);
      expect(s.fontWeight, FontWeight.w600);
      expect(s.fontVariations, [const FontVariation('wght', 600)]);
    });
    test('monoStyle uses the mono font one px smaller', () {
      const c = DisplayConfig(monoFont: 'JetBrains Mono', baseSize: 15);
      final s = c.monoStyle;
      expect(s.fontFamily, 'JetBrains Mono');
      expect(s.fontSize, 14);
    });
  });
}
