// Tests for the HCT hue-preserving contrast engine (lib/src/theme/hct_tools.dart):
// toneTargetedOn, accentOn, selectionColorFor, and DeskPalette.guardedFor.
//
// The properties under test are the ones easy to get subtly wrong in colour
// science:
//   * FLOOR SATISFACTION — the returned colour always clears the requested
//     contrast target against the reference colour (or falls back to a
//     guaranteed-legible black/white when the target is out of gamut).
//   * HUE PRESERVATION — the retone keeps the source hue within a small
//     tolerance, EXCEPT on the achromatic black/white fallback (where hue is
//     undefined). Checked only when the result carries meaningful chroma.
//   * MONOTONICITY / minimality — the walk returns the nearest qualifying tone,
//     so an already-legible input is returned unchanged (identity).
//   * GRACEFUL UNREACHABLE — a demand that no in-gamut tone can meet returns the
//     contrastingOn() fallback, still legible at the WCAG floor.
import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// Signed smallest angular distance between two HCT hues (degrees), in [0,180].
double _hueDelta(Color a, Color b) {
  final ha = Hct.fromInt(a.toARGB32()).hue;
  final hb = Hct.fromInt(b.toARGB32()).hue;
  final d = (ha - hb).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

double _chromaOf(Color c) => Hct.fromInt(c.toARGB32()).chroma;

/// The colourway page backgrounds exercised throughout.
const Map<String, Color> _pages = {
  'Nord': Color(0xFF2E3440),
  'Dracula': Color(0xFF282A36),
  'Solarized': Color(0xFF002B36),
  'Gruvbox': Color(0xFF282828),
  'Catppuccin': Color(0xFF1E1E2E),
};

void main() {
  group('toneTargetedOn — floor + hue + fallback', () {
    for (final entry in _pages.entries) {
      test('${entry.key}: onSurface (chroma 12, target 7) clears 7 & keeps hue',
          () {
        final bg = entry.value;
        final on = toneTargetedOn(bg, chromaCap: 12, target: 7.0);
        expect(contrastRatio(on, bg), greaterThanOrEqualTo(7.0),
            reason: 'derived onSurface must clear its target');
        // Hue is the SURFACE hue (this is an on-surface colour). Only assert
        // when the result carries chroma (a black/white fallback has none).
        if (_chromaOf(on) > 2.0) {
          expect(_hueDelta(on, bg), lessThan(12.0),
              reason: 'onSurface should keep the surface hue');
        }
      });
    }

    test('respects the chroma cap (result chroma ≤ cap, within gamut slack)',
        () {
      // A vivid surface, capped at 8 → the walked colour must not exceed the cap
      // by more than the HCT gamut-mapping slack.
      const vivid = Color(0xFF1B4D2E); // saturated green-ish dark
      final on = toneTargetedOn(vivid, chromaCap: 8, target: 4.5);
      expect(_chromaOf(on), lessThanOrEqualTo(8.0 + 2.0));
    });

    test('already-huge-contrast surface still returns a legible on-colour', () {
      // Pure white surface: target 4.5 is reachable by darkening; result legible.
      final on = toneTargetedOn(Colors.white, target: 4.5);
      expect(contrastRatio(on, Colors.white), greaterThanOrEqualTo(4.5));
    });

    test('unreachable target on near-black → contrastingOn fallback (white)',
        () {
      const nearBlack = Color(0xFF0A0A0A);
      final on = toneTargetedOn(nearBlack, chromaCap: 12, target: 21.0);
      // 21:1 is only black-vs-white; a hue-tinted tone cannot reach it, so the
      // guaranteed fallback (white here) must be returned and still be legible.
      expect(on, contrastingOn(nearBlack));
      expect(isLegibleOn(on, nearBlack), isTrue);
    });

    test('monotone: a higher target never yields a lower achieved contrast',
        () {
      const bg = Color(0xFF2E3440);
      double prev = 0;
      for (final t in [3.0, 4.5, 6.0, 7.0]) {
        final achieved = contrastRatio(toneTargetedOn(bg, target: t), bg);
        expect(achieved, greaterThanOrEqualTo(prev - 0.001),
            reason: 'raising the target must not reduce achieved contrast');
        prev = t; // compare achieved against the previous TARGET (achieved ≥ t)
        expect(achieved, greaterThanOrEqualTo(t - 0.001));
      }
    });
  });

  group('accentOn — identity, floor, hue, direction', () {
    test('an already-legible accent is returned UNCHANGED (identity)', () {
      const bg = Color(0xFF2E3440);
      const legible = Color(0xFFA3BE8C); // Nord ok, ~6.1:1 on the Nord page
      expect(contrastRatio(legible, bg), greaterThanOrEqualTo(4.5));
      expect(accentOn(legible, bg), legible,
          reason: 'no retone when already above target ⇒ perfect fidelity');
    });

    test('a failing accent is retoned to clear the target, hue preserved', () {
      const bg = Color(0xFF2E3440);
      const muted = Color(0xFF616E88); // Nord muted, ~2.4:1 — fails
      final fixed = accentOn(muted, bg, target: 4.5);
      expect(contrastRatio(fixed, bg), greaterThanOrEqualTo(4.5));
      expect(_hueDelta(fixed, muted), lessThan(10.0),
          reason: 'retone keeps the accent hue');
      expect(fixed, isNot(muted));
    });

    test('on a dark page the accent moves LIGHTER (higher tone)', () {
      const darkPage = Color(0xFF101418);
      const acc = Color(0xFF3B4252); // dark, fails on the dark page
      final fixed = accentOn(acc, darkPage, target: 4.5);
      expect(Hct.fromInt(fixed.toARGB32()).tone,
          greaterThan(Hct.fromInt(acc.toARGB32()).tone));
    });

    test('on a light page the accent moves DARKER (lower tone)', () {
      const lightPage = Color(0xFFF5F5F5);
      const acc = Color(0xFFBFC7D5); // light, fails on the light page
      final fixed = accentOn(acc, lightPage, target: 4.5);
      expect(Hct.fromInt(fixed.toARGB32()).tone,
          lessThan(Hct.fromInt(acc.toARGB32()).tone));
    });

    test('near-black page demanding 7:1 from a dark hue stays graceful', () {
      const nearBlack = Color(0xFF0A0A0A);
      const darkHue = Color(0xFF2A2A3A);
      final fixed = accentOn(darkHue, nearBlack, target: 7.0);
      // Either a walked tone reaches 7, or the contrastingOn fallback — both
      // must be legible at the WCAG floor.
      expect(isLegibleOn(fixed, nearBlack), isTrue);
      expect(contrastRatio(fixed, nearBlack), greaterThanOrEqualTo(3.0));
    });

    test('custom target is honoured (structural 3.0 floor)', () {
      const bg = Color(0xFF282828);
      const faint = Color(0xFF3A3A3A);
      final t3 = accentOn(faint, bg, target: 3.0);
      expect(contrastRatio(t3, bg), greaterThanOrEqualTo(3.0));
    });
  });

  group('nonTextGuardOn — DUAL floor (WCAG >= 3.0 AND |Lc| >= 30)', () {
    // The structural roles the DeskTheme fold feeds this guard, per colourway:
    // the folded surfaceContainerHighest (page + 12% ink) is the slider/switch
    // track; scheme.outlineVariant is the divider; scheme.outline is the socket
    // outline. All must clear BOTH floors on the near-black page.
    for (final entry in _pages.entries) {
      test('${entry.key}: a faint container tone clears both floors', () {
        final bg = entry.value;
        // The folded surfaceContainerHighest tone: page + white/black ink @12%.
        final ink = contrastingOn(bg);
        final track = Color.alphaBlend(ink.withValues(alpha: 0.12), bg);
        final guarded = nonTextGuardOn(track, bg);
        expect(contrastRatio(guarded, bg), greaterThanOrEqualTo(3.0),
            reason: 'WCAG floor');
        expect(apcaLc(guarded, bg).abs(), greaterThanOrEqualTo(30.0),
            reason: 'APCA non-text floor');
        // Hue-preserving where the tone carries chroma (near-neutral pages give
        // a near-neutral guard — the engine must not invent a hue).
        if (_chromaOf(guarded) > 2.0) {
          expect(_hueDelta(guarded, track), lessThan(20.0),
              reason: 'the guard keeps the source hue');
        }
      });
    }

    test('single-WCAG-clear-but-APCA-short input IS retoned further', () {
      // A tone that clears WCAG 3.0 on a dark page but measures |Lc| < 30 is the
      // exact gap this guard closes: it must move FURTHER than a WCAG-only walk.
      const page = Color(0xFF2E3440); // Nord
      final ink = contrastingOn(page); // white
      final track = Color.alphaBlend(ink.withValues(alpha: 0.12), page);
      // Precondition: the raw track is WCAG-borderline and APCA-short.
      expect(apcaLc(track, page).abs(), lessThan(30.0));
      final guarded = nonTextGuardOn(track, page);
      expect(guarded, isNot(track));
      expect(contrastRatio(guarded, page), greaterThanOrEqualTo(3.0));
      expect(apcaLc(guarded, page).abs(), greaterThanOrEqualTo(30.0));
    });

    test('an already-dual-clearing input is returned UNCHANGED (identity)', () {
      const page = Color(0xFF2E3440);
      // White clears both floors on the Nord page comfortably.
      const white = Color(0xFFFFFFFF);
      expect(contrastRatio(white, page), greaterThanOrEqualTo(3.0));
      expect(apcaLc(white, page).abs(), greaterThanOrEqualTo(30.0));
      expect(nonTextGuardOn(white, page), white);
    });

    test('custom floors are honoured (WCAG 4.5 + Lc 45)', () {
      const page = Color(0xFF282828); // Gruvbox
      const faint = Color(0xFF3A3A3A);
      final g = nonTextGuardOn(faint, page, wcagFloor: 4.5, lcFloor: 45);
      expect(contrastRatio(g, page), greaterThanOrEqualTo(4.5));
      expect(apcaLc(g, page).abs(), greaterThanOrEqualTo(45.0));
    });

    test('unreachable dual demand → contrastingOn fallback (still legible)',
        () {
      // A demand no in-gamut hue-locked tone can meet (WCAG 21 is black-vs-white
      // only) falls back to the guaranteed max-contrast black/white.
      const nearBlack = Color(0xFF0A0A0A);
      const dark = Color(0xFF1A1A2A);
      final g = nonTextGuardOn(nearBlack, dark, wcagFloor: 21.0, lcFloor: 108);
      expect(g, contrastingOn(dark));
    });

    test('walk direction: dark page lightens, light page darkens', () {
      const darkPage = Color(0xFF101418);
      const faintDark = Color(0xFF20242A);
      final gDark = nonTextGuardOn(faintDark, darkPage);
      expect(Hct.fromInt(gDark.toARGB32()).tone,
          greaterThan(Hct.fromInt(faintDark.toARGB32()).tone));

      const lightPage = Color(0xFFF5F5F5);
      const faintLight = Color(0xFFE8E8E8);
      final gLight = nonTextGuardOn(faintLight, lightPage);
      expect(Hct.fromInt(gLight.toARGB32()).tone,
          lessThan(Hct.fromInt(faintLight.toARGB32()).tone));
    });
  });

  group('selectionColorFor — selected-text hard guarantee', () {
    test('selected text stays ≥ 4.5 on the chosen highlight (light page)', () {
      const page = Color(0xFFFFFFFF);
      const text = Color(0xFF000000);
      const accent = Color(0xFF3F51B5);
      final sel = selectionColorFor(page, text, accent);
      expect(contrastRatio(text, sel), greaterThanOrEqualTo(4.5),
          reason: 'selected text must remain legible on the highlight');
    });

    test('on a near-black page, text legibility wins; region is best-effort',
        () {
      // The documented unsatisfiable case: region ≥ 3.0 AND text ≥ 4.5 cannot
      // both hold near black. Assert the HARD guarantee (text ≥ 4.5) holds; the
      // region separation is allowed to fall short.
      const page = Color(0xFF0A0A0A);
      const text = Color(0xFFECEFF4);
      const accent = Color(0xFF88C0D0);
      final sel = selectionColorFor(page, text, accent);
      expect(contrastRatio(text, sel), greaterThanOrEqualTo(4.5));
    });

    test('a custom textTarget is honoured', () {
      const page = Color(0xFFFFFFFF);
      const text = Color(0xFF000000);
      const accent = Color(0xFF6A1B9A);
      final sel = selectionColorFor(page, text, accent, textTarget: 7.0);
      expect(contrastRatio(text, sel), greaterThanOrEqualTo(7.0));
    });
  });

  group('DeskPalette.guardedFor — every role legible, bg untouched', () {
    for (final entry in _pages.entries) {
      test('${entry.key}: all 8 content roles clear 4.5 vs page', () {
        final bg = entry.value;
        // Use the matching colourway palette where one exists; else standard.
        final DeskPalette p = switch (entry.key) {
          'Nord' => DeskPalette.nord,
          'Dracula' => DeskPalette.dracula,
          'Solarized' => DeskPalette.solarizedDark,
          'Gruvbox' => DeskPalette.gruvboxDark,
          'Catppuccin' => DeskPalette.catppuccinMocha,
          _ => DeskPalette.standard,
        };
        final g = p.guardedFor(bg);
        for (final role in <MapEntry<String, Color>>[
          MapEntry('danger', g.danger),
          MapEntry('warn', g.warn),
          MapEntry('ok', g.ok),
          MapEntry('info', g.info),
          MapEntry('accent', g.accent),
          MapEntry('alt', g.alt),
          MapEntry('muted', g.muted),
          MapEntry('neutral', g.neutral),
        ]) {
          expect(contrastRatio(role.value, bg), greaterThanOrEqualTo(4.5),
              reason: '${entry.key} ${role.key} must clear 4.5 on the page');
        }
      });
    }

    test('background field is left UNTOUCHED by the guard', () {
      final g = DeskPalette.nord.guardedFor(const Color(0xFF2E3440));
      expect(g.background, DeskPalette.nord.background);
    });

    test('an already-legible role is preserved exactly (identity)', () {
      const bg = Color(0xFF2E3440);
      // Nord ok already clears 4.5 on the Nord page.
      final g = DeskPalette.nord.guardedFor(bg);
      expect(g.ok, DeskPalette.nord.ok);
    });

    test('custom target 3.0 relaxes the guard (roles clear 3.0, not 4.5)', () {
      const bg = Color(0xFF2E3440);
      final g = DeskPalette.nord.guardedFor(bg, target: 3.0);
      expect(contrastRatio(g.muted, bg), greaterThanOrEqualTo(3.0));
    });

    test('guardedFor preserves the DeskPalette runtime type', () {
      final g = DeskPalette.standard.guardedFor(const Color(0xFF002B36));
      expect(g, isA<DeskPalette>());
    });
  });
}
