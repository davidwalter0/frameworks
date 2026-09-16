import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('relativeLuminance', () {
    test('black ≈ 0, white ≈ 1', () {
      expect(relativeLuminance(const Color(0xFF000000)), closeTo(0.0, 1e-9));
      expect(relativeLuminance(const Color(0xFFFFFFFF)), closeTo(1.0, 1e-9));
    });
  });

  group('contrastRatio', () {
    test('black vs white is 21', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21.0, 0.01));
    });
    test('identical colours is 1', () {
      const c = Color(0xFF123456);
      expect(contrastRatio(c, c), closeTo(1.0, 1e-9));
    });
    test('symmetric in its arguments', () {
      const a = Color(0xFF222222);
      const b = Color(0xFFDDDDDD);
      expect(contrastRatio(a, b), closeTo(contrastRatio(b, a), 1e-9));
    });
  });

  group('isLegibleOn / contrastingOn', () {
    test('kMinContrast is the WCAG AA threshold 3.0', () {
      expect(kMinContrast, 3.0);
    });
    test('white on near-white is illegible; black is chosen', () {
      const bg = Color(0xFFF5F5F5);
      expect(isLegibleOn(Colors.white, bg), isFalse);
      expect(contrastingOn(bg), Colors.black);
    });
    test('on a dark background white is chosen and legible', () {
      const bg = Color(0xFF202020);
      expect(contrastingOn(bg), Colors.white);
      expect(isLegibleOn(Colors.white, bg), isTrue);
    });
  });
}
