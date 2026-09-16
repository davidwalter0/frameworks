// Invariants for the HCT engine wired into DeskTheme._build (deliverables B, C,
// D). These exercise the BUILT ThemeData (not the helpers in isolation) under
// each colourway's own dark page override, asserting that every role a widget
// reads clears its floor against the page while the colourway hue survives.
//
// The measured numbers these lock in (page-override active, light mode
// requested — brightness follows the page):
//   Nord onSurface 7.02, onSurfaceVariant 6.10, primary 7.31, inverseSurface
//   12.49, palette-muted 2.43->4.53, selection region 2.70 (best-effort) /
//   selected-text 4.63.
// The dual-floor (WCAG >= 3.0 AND |APCA Lc| >= 30) structural guards
// ([nonTextGuardOn]) now land the faint roles at (Nord): slider track
// w3.35/Lc30.7, divider w3.32/Lc30.4, switch OFF track w3.35/Lc30.7, switch OFF
// outline (= folded scheme.outline) w3.94/Lc36.8. (The old WCAG-only guard left
// slider/divider at w~3.0 but |Lc| ~23–28 — below the non-text APCA floor.)
// Nord's selection region (2.70 < 3.0) is the documented unsatisfiable case:
// "region >= 3.0 AND selected-text >= 4.5" has an empty luminance window on a
// near-black page, so selected-TEXT legibility wins and region is best-effort.
import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// (seed hex, page-background hex, colourway palette) per named colourway.
final Map<String, (String, String, DeskPalette)> _colourways = {
  'Nord': ('81A1C1', '2E3440', DeskPalette.nord),
  'Dracula': ('BD93F9', '282A36', DeskPalette.dracula),
  'Solarized': ('268BD2', '002B36', DeskPalette.solarizedDark),
  'Gruvbox': ('8EC07C', '282828', DeskPalette.gruvboxDark),
};

double _hueDelta(Color a, Color b) {
  final d =
      (Hct.fromInt(a.toARGB32()).hue - Hct.fromInt(b.toARGB32()).hue).abs() %
          360.0;
  return d > 180.0 ? 360.0 - d : d;
}

ThemeData _themeFor(String name) {
  final (seed, bg, pal) = _colourways[name]!;
  return DeskTheme.light(
    palette: pal,
    seedColorHex: seed,
    backgroundOverride: bg,
  );
}

Color _pageOf(String name) => DeskTheme.hexToColor(_colourways[name]!.$2)!;

void main() {
  // ── B · Strategy C scheme retone ────────────────────────────────────────────
  group('B · scheme retone (onSurface + accents clear floor, keep hue)', () {
    for (final name in _colourways.keys) {
      test('$name: onSurface & onSurfaceVariant clear the WCAG floor on page',
          () {
        final t = _themeFor(name);
        final page = _pageOf(name);
        expect(contrastRatio(t.colorScheme.onSurface, page),
            greaterThanOrEqualTo(kMinContrast));
        expect(contrastRatio(t.colorScheme.onSurfaceVariant, page),
            greaterThanOrEqualTo(kMinContrast));
        // The retone targets are 7 / 6 — assert the comfortable margin, not just
        // the bare floor, so a regression that drops back to the 3.0 fold shows.
        expect(contrastRatio(t.colorScheme.onSurface, page),
            greaterThanOrEqualTo(6.5));
        expect(contrastRatio(t.colorScheme.onSurfaceVariant, page),
            greaterThanOrEqualTo(5.5));
      });

      test('$name: onSurface tracks the page chroma (tints iff page is tinted)',
          () {
        // Strategy C preserves the SURFACE hue at a capped chroma. A chromatic
        // page (Nord/Dracula/Solarized) yields a hue-tinted onSurface — the
        // whole point, "no flat ink". A near-neutral page (Gruvbox #282828,
        // chroma ~1) has no hue to preserve, so a NEUTRAL onSurface is the
        // correct, faithful result (the engine must not invent a hue). Assert
        // the right behaviour for each: tinted when the page is tinted, quiet
        // when it is not.
        final t = _themeFor(name);
        final page = _pageOf(name);
        final pageChroma = Hct.fromInt(page.toARGB32()).chroma;
        final onChroma = Hct.fromInt(t.colorScheme.onSurface.toARGB32()).chroma;
        if (pageChroma > 3.0) {
          expect(onChroma, greaterThan(1.5),
              reason: 'a tinted page must give a colourway-tinted onSurface');
        } else {
          // A neutral page must not manufacture a saturated onSurface.
          expect(onChroma, lessThan(4.0),
              reason: 'a neutral page must keep onSurface near-neutral');
        }
      });

      test('$name: primary/secondary/tertiary clear the floor on the page', () {
        final t = _themeFor(name);
        final page = _pageOf(name);
        expect(contrastRatio(t.colorScheme.primary, page),
            greaterThanOrEqualTo(kMinContrast));
        expect(contrastRatio(t.colorScheme.secondary, page),
            greaterThanOrEqualTo(kMinContrast));
        expect(contrastRatio(t.colorScheme.tertiary, page),
            greaterThanOrEqualTo(kMinContrast));
      });

      test('$name: on-accent colours pair with the retoned accents (>= 4.5)',
          () {
        // A filled button's label must stay legible even after the accent moved.
        final t = _themeFor(name);
        final cs = t.colorScheme;
        expect(
            contrastRatio(cs.onPrimary, cs.primary), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(cs.onSecondary, cs.secondary),
            greaterThanOrEqualTo(4.5));
        expect(contrastRatio(cs.onTertiary, cs.tertiary),
            greaterThanOrEqualTo(4.5));
      });

      test('$name: retoned primary keeps the seed hue within tolerance', () {
        final t = _themeFor(name);
        final seed = DeskTheme.hexToColor(_colourways[name]!.$1)!;
        // The M3 scheme already rotates hue slightly for tonal harmony; assert
        // the retone does not further wander far from the seed family.
        expect(_hueDelta(t.colorScheme.primary, seed), lessThan(30.0));
      });
    }

    test('body text remains the flat WCAG-guarded fg (outer guarantee intact)',
        () {
      // onSurface is now hue-tinted, but the actual body text colour must still
      // be the guaranteed contrastingOn ink — the outer guarantee for reading.
      final t = _themeFor('Nord');
      final page = _pageOf('Nord');
      expect(t.textTheme.bodyLarge?.color, contrastingOn(page));
      expect(isLegibleOn(t.textTheme.bodyLarge!.color!, page), isTrue);
    });

    test('no override → scheme roles are byte-identical to M3 (untouched)', () {
      final t = DeskTheme.light(palette: DeskPalette.nord);
      final m3 = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1565C0),
        brightness: Brightness.light,
      );
      // The whole HCT pipeline is gated on an override; with none, every role
      // matches plain fromSeed.
      expect(t.colorScheme.primary, m3.primary);
      expect(t.colorScheme.onSurface, m3.onSurface);
      expect(t.colorScheme.onSurfaceVariant, m3.onSurfaceVariant);
      expect(t.colorScheme.inverseSurface, m3.inverseSurface);
      // outline / outlineVariant are the untouched M3 values too.
      expect(t.colorScheme.outline, m3.outline);
      expect(t.colorScheme.outlineVariant, m3.outlineVariant);
      // And no widget guards are attached.
      expect(t.sliderTheme.inactiveTrackColor, isNull);
      expect(t.dividerTheme.color, isNull);
      expect(t.switchTheme.trackColor, isNull);
      expect(t.switchTheme.trackOutlineColor, isNull);
      expect(t.textSelectionTheme.selectionColor, isNull);
      expect(t.textSelectionTheme.cursorColor, isNull);
    });
  });

  // ── C · structural widget-theme guards + guarded palette ────────────────────
  group('C · structural guards (slider / divider / selection / palette)', () {
    for (final name in _colourways.keys) {
      test('$name: slider inactive track clears BOTH floors vs page', () {
        // Dual-floor: WCAG >= 3.0 AND |Lc| >= 30. The old WCAG-only guard left
        // this at |Lc| ~23–27 (visibly faint); the second floor closes that gap.
        final t = _themeFor(name);
        final page = _pageOf(name);
        final track = t.sliderTheme.inactiveTrackColor;
        expect(track, isNotNull);
        expect(contrastRatio(track!, page), greaterThanOrEqualTo(kMinContrast),
            reason: 'slider track WCAG floor');
        expect(
            apcaLc(track, page).abs(), greaterThanOrEqualTo(kApcaNonTextFloor),
            reason: 'slider track APCA non-text floor (30)');
      });

      test('$name: divider colour clears BOTH floors vs page', () {
        final t = _themeFor(name);
        final page = _pageOf(name);
        final divider = t.dividerTheme.color;
        expect(divider, isNotNull);
        expect(
            contrastRatio(divider!, page), greaterThanOrEqualTo(kMinContrast),
            reason: 'divider WCAG floor');
        expect(apcaLc(divider, page).abs(),
            greaterThanOrEqualTo(kApcaNonTextFloor),
            reason: 'divider APCA non-text floor (30)');
      });

      test('$name: Switch OFF track fill + outline clear BOTH floors vs page',
          () {
        // The un-selected switch: its track fill and "sunk socket" outline stroke
        // must both read on the page. ON states are left to M3 (null resolvers).
        final t = _themeFor(name);
        final page = _pageOf(name);
        final offTrack =
            t.switchTheme.trackColor?.resolve(const <WidgetState>{});
        final offOutline =
            t.switchTheme.trackOutlineColor?.resolve(const <WidgetState>{});
        expect(offTrack, isNotNull);
        expect(offOutline, isNotNull);
        for (final role in <(String, Color)>[
          ('OFF track', offTrack!),
          ('OFF outline', offOutline!),
        ]) {
          expect(
              contrastRatio(role.$2, page), greaterThanOrEqualTo(kMinContrast),
              reason: '${role.$1} WCAG floor');
          expect(apcaLc(role.$2, page).abs(),
              greaterThanOrEqualTo(kApcaNonTextFloor),
              reason: '${role.$1} APCA non-text floor (30)');
        }
      });

      test('$name: Switch ON states are left to M3 (resolver returns null)',
          () {
        // The selected state must NOT be overridden — Material keeps its own
        // primary track / onPrimary thumb (which already pass).
        final t = _themeFor(name);
        const on = {WidgetState.selected};
        expect(t.switchTheme.trackColor?.resolve(on), isNull,
            reason: 'ON track stays M3 default');
        expect(t.switchTheme.trackOutlineColor?.resolve(on), isNull,
            reason: 'ON has no outline override');
      });

      test('$name: scheme.outline (semantic border) clears BOTH floors vs page',
          () {
        // The dual-floor outline fold: bordered controls reading scheme.outline
        // (OutlinedButton side, focus rings) are delineated on the page. Nord's
        // M3 outline was w2.97 — below even the WCAG floor — before this fold.
        final t = _themeFor(name);
        final page = _pageOf(name);
        expect(contrastRatio(t.colorScheme.outline, page),
            greaterThanOrEqualTo(kMinContrast),
            reason: 'outline WCAG floor');
        expect(apcaLc(t.colorScheme.outline, page).abs(),
            greaterThanOrEqualTo(kApcaNonTextFloor),
            reason: 'outline APCA non-text floor (30)');
      });

      test('$name: outlineVariant is LEFT to M3 (decorative hairline, exempt)',
          () {
        // Deliverable-2 boundary: the decorative hairline role is intentionally
        // NOT guarded (M3-intentional low contrast). Assert it stays the plain
        // fromSeed value so a future accidental guard would surface here.
        final (seed, _, __) = _colourways[name]!;
        final m3 = ColorScheme.fromSeed(
          seedColor: DeskTheme.hexToColor(seed)!,
          brightness: Brightness.dark,
        );
        expect(_themeFor(name).colorScheme.outlineVariant, m3.outlineVariant);
      });

      test('$name: SELECTED TEXT stays >= 4.5 on the selection highlight', () {
        // The hard guarantee. The rendered selected-text colour is the body fg
        // (contrastingOn(page)); it must stay legible on the managed highlight.
        final t = _themeFor(name);
        final sel = t.textSelectionTheme.selectionColor;
        expect(sel, isNotNull);
        final selectedText = t.textTheme.bodyLarge!.color!;
        expect(contrastRatio(selectedText, sel!), greaterThanOrEqualTo(4.5),
            reason: 'selected text must remain legible on the highlight');
      });

      test('$name: every DeskPalette role >= 3.0 vs page (guarded palette)',
          () {
        final t = _themeFor(name);
        final page = _pageOf(name);
        final p = t.extension<DeskPalette>()!;
        for (final role in <MapEntry<String, Color>>[
          MapEntry('danger', p.danger),
          MapEntry('warn', p.warn),
          MapEntry('ok', p.ok),
          MapEntry('info', p.info),
          MapEntry('accent', p.accent),
          MapEntry('alt', p.alt),
          MapEntry('muted', p.muted),
          MapEntry('neutral', p.neutral),
        ]) {
          expect(contrastRatio(role.value, page),
              greaterThanOrEqualTo(kMinContrast),
              reason: '$name palette ${role.key} must clear 3.0 on the page');
        }
      });
    }

    test('Nord selection REGION is best-effort (documented < 3.0 case)', () {
      // Nord's near-black page is the luminance-unsatisfiable case: keeping
      // selected text >= 4.5 forces the highlight close enough to the page that
      // the REGION separation drops below 3.0. This asserts the design choice —
      // text legibility is honoured, region is NOT required — so a future change
      // that silently sacrifices text legibility to chase region would surface.
      final t = _themeFor('Nord');
      final sel = t.textSelectionTheme.selectionColor!;
      final selectedText = t.textTheme.bodyLarge!.color!;
      expect(contrastRatio(selectedText, sel), greaterThanOrEqualTo(4.5));
      // Region is allowed to be below the floor here (measured ~2.70); we only
      // record that text won the trade-off, not a hard region bound.
      expect(contrastRatio(sel, _pageOf('Nord')), lessThan(4.5));
    });

    test('guarded palette preserves an already-legible role exactly', () {
      // Nord ok already clears the floor on the Nord page → unchanged.
      final t = _themeFor('Nord');
      expect(t.extension<DeskPalette>()!.ok, DeskPalette.nord.ok);
    });
  });

  // ── D · inverse-surface fold ────────────────────────────────────────────────
  group('D · inverse-surface fold (SnackBar counterpoint from the override)',
      () {
    for (final name in _colourways.keys) {
      test('$name: onInverseSurface vs inverseSurface >= 4.5 (SnackBar text)',
          () {
        final cs = _themeFor(name).colorScheme;
        expect(contrastRatio(cs.onInverseSurface, cs.inverseSurface),
            greaterThanOrEqualTo(4.5));
      });

      test('$name: inverseSurface vs page >= 3.0 (a real counterpoint)', () {
        final t = _themeFor(name);
        expect(contrastRatio(t.colorScheme.inverseSurface, _pageOf(name)),
            greaterThanOrEqualTo(kMinContrast));
      });

      test('$name: inversePrimary is legible ON the inverse surface', () {
        // inversePrimary (e.g. a SnackBar action label) sits on inverseSurface,
        // not the page — so it is retoned against the inverse surface.
        final cs = _themeFor(name).colorScheme;
        expect(contrastRatio(cs.inversePrimary, cs.inverseSurface),
            greaterThanOrEqualTo(kMinContrast));
      });
    }

    test(
        'mid-grey page: inverseSurface still clears 3.0 (hard case documented)',
        () {
      // A near-mid page is where a strong counterpoint is least reachable while
      // staying on the page hue; the max-contrast tone must still clear 3.0
      // (black/white are always candidates).
      final t = DeskTheme.light(
        palette: DeskPalette.standard,
        backgroundOverride: '808080',
      );
      expect(
        contrastRatio(t.colorScheme.inverseSurface, const Color(0xFF808080)),
        greaterThanOrEqualTo(kMinContrast),
      );
    });

    test('no override → inverse roles are the untouched M3 values', () {
      final t = DeskTheme.light(palette: DeskPalette.dracula);
      final m3 = ColorScheme.fromSeed(
        seedColor: const Color(0xFF1565C0),
        brightness: Brightness.light,
      );
      expect(t.colorScheme.inverseSurface, m3.inverseSurface);
      expect(t.colorScheme.onInverseSurface, m3.onInverseSurface);
      expect(t.colorScheme.inversePrimary, m3.inversePrimary);
    });
  });
}
