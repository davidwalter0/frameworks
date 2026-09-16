// Tests for the promoted APCA-W3 0.1.9 metric (lib/src/theme/apca.dart).
//
// The pins below are the values THIS implementation produces (captured from the
// code, cross-checked against the published APCA-W3 0.1.9 reference points:
// black-on-white ≈ Lc 106.04, white-on-black ≈ Lc -107.88). They lock the
// constants against accidental "tidying" — any change to a coefficient moves
// these numbers.
import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('apcaLc — polarity + reference values', () {
    test('black on white is strongly positive (normal polarity)', () {
      final lc = apcaLc(Colors.black, Colors.white);
      expect(lc, greaterThan(0));
      // Published APCA-W3 0.1.9 reference ≈ 106.04.
      expect(lc, closeTo(106.04, 0.1));
    });

    test('white on black is strongly negative (reverse polarity)', () {
      final lc = apcaLc(Colors.white, Colors.black);
      expect(lc, lessThan(0));
      // Published APCA-W3 0.1.9 reference ≈ -107.88.
      expect(lc, closeTo(-107.88, 0.1));
    });

    test('polarity magnitudes differ (APCA is NOT symmetric like WCAG)', () {
      // The whole point of APCA vs WCAG 2.x: reverse polarity is weighted
      // differently, so |white-on-black| != |black-on-white|.
      final normal = apcaLc(Colors.black, Colors.white).abs();
      final reverse = apcaLc(Colors.white, Colors.black).abs();
      expect((normal - reverse).abs(), greaterThan(1.0));
    });

    test('identical colours → exactly 0 (deltaYmin guard)', () {
      expect(apcaLc(const Color(0xFF808080), const Color(0xFF808080)), 0.0);
      expect(apcaLc(Colors.white, Colors.white), 0.0);
      expect(apcaLc(Colors.black, Colors.black), 0.0);
    });

    test('a mid-grey on white sits between (known reference)', () {
      // #595959 on white is a commonly-cited APCA sample (~Lc 84).
      final lc = apcaLc(const Color(0xFF595959), Colors.white);
      expect(lc, closeTo(84.29, 0.2));
    });
  });

  group('apcaLc — monotonicity', () {
    test('|Lc| rises as text darkens on a fixed white background', () {
      // Normal polarity: darker text ⇒ more contrast ⇒ larger positive Lc.
      double prev = -1;
      for (final tone in [0xEE, 0xCC, 0xAA, 0x88, 0x66, 0x44, 0x22, 0x00]) {
        final c = Color.fromARGB(0xFF, tone, tone, tone);
        final lc = apcaLc(c, Colors.white);
        expect(lc, greaterThanOrEqualTo(prev),
            reason: 'darker text on white must not lose contrast');
        prev = lc;
      }
    });

    test('|Lc| rises as text lightens on a fixed black background', () {
      // Reverse polarity: lighter text ⇒ more contrast ⇒ larger magnitude
      // (more negative Lc).
      double prevMag = -1;
      for (final tone in [0x11, 0x33, 0x55, 0x77, 0x99, 0xBB, 0xDD, 0xFF]) {
        final c = Color.fromARGB(0xFF, tone, tone, tone);
        final mag = apcaLc(c, Colors.black).abs();
        expect(mag, greaterThanOrEqualTo(prevMag),
            reason: 'lighter text on black must not lose contrast');
        prevMag = mag;
      }
    });

    test('near-equal luminances stay below any usable floor', () {
      // A 1-step grey difference is essentially invisible → tiny |Lc|.
      final lc = apcaLc(const Color(0xFF808080), const Color(0xFF818181)).abs();
      expect(lc, lessThan(kApcaNonTextFloor));
    });
  });

  group('apcaTextFloor — size/weight ladder', () {
    test('tier boundaries at the documented breakpoints (weight 400)', () {
      expect(apcaTextFloor(11, 400), 100); // < 12
      expect(apcaTextFloor(12, 400), 90);
      expect(apcaTextFloor(13, 400), 90);
      expect(apcaTextFloor(14, 400), 75); // body
      expect(apcaTextFloor(17, 400), 75);
      expect(apcaTextFloor(18, 400), 60);
      expect(apcaTextFloor(23, 400), 60);
      expect(apcaTextFloor(24, 400), 45);
      expect(apcaTextFloor(31, 400), 45);
      expect(apcaTextFloor(32, 400), 30); // ≥ 32
      expect(apcaTextFloor(48, 400), 30);
    });

    test('bold (≥700) relaxes exactly one tier', () {
      // 14px regular → 75; bold → next tier down (60).
      expect(apcaTextFloor(14, 700), 60);
      expect(apcaTextFloor(14, 900), 60);
      // Floor tier already at the loosest stays clamped (32px → 30).
      expect(apcaTextFloor(32, 700), 30);
    });

    test('light (≤300) tightens exactly one tier', () {
      // 14px regular → 75; light → next tier up (90).
      expect(apcaTextFloor(14, 300), 90);
      expect(apcaTextFloor(14, 100), 90);
      // Tightest tier already 100 stays clamped (11px → 100).
      expect(apcaTextFloor(11, 300), 100);
    });

    test('regular weight (400..600) does not shift', () {
      expect(apcaTextFloor(14, 400), 75);
      expect(apcaTextFloor(14, 500), 75);
      expect(apcaTextFloor(14, 600), 75);
    });
  });

  group('APCA floor constants', () {
    test('the three bronze tiers are the documented magnitudes', () {
      expect(kApcaBodyFloor, 60.0);
      expect(kApcaLargeFloor, 45.0);
      expect(kApcaNonTextFloor, 30.0);
    });
  });
}
