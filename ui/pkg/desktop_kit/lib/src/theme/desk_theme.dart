// Builds a desktop ThemeData for light/dark from a [DeskPalette] (passed in by
// the app — possibly a subclass) plus the user's fonts and optional
// seed/background/foreground overrides. The palette is attached as a
// [ThemeExtension] so content widgets read it from context, and because the app
// passes its OWN palette instance it is stored and lerped as that subtype.
//
// Ported from alert-log's AppTheme, generalized over the palette:
// where AppTheme took a ThemePreset (seed + bgHex + NotifPalette), DeskTheme
// takes the palette directly plus an explicit seed/background. Same WCAG-guarded
// foreground logic (a chosen text colour is honoured only when legible against
// the page background, else a guaranteed-contrasting colour is derived).
library;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'contrast.dart';
import 'desk_palette.dart';
import 'font_tools.dart';
import 'hct_tools.dart';

/// Fallback Material seed when no (valid) [DeskTheme.light]/[DeskTheme.dark]
/// `seedColorHex` is supplied — the original project blue.
const Color _kDefaultSeed = Color(0xFF1565C0);

/// Builds the desktop [ThemeData] for light or dark mode from a [DeskPalette]
/// and optional overrides.
///
/// ── Custom-editor selection contract (READ THIS if you embed ANY editor that
/// takes its own selection colours) ───────────────────────────────────────────
/// No package in this family depends on `re_editor` any more — it was dropped
/// 2026-07-29 with the example gallery. It is still named below because its
/// default IS the hazard, and any hand-rolled editor can reproduce it.
///
/// When a background override is active this builder installs a MANAGED
/// [TextSelectionThemeData]: [TextSelectionThemeData.selectionColor] is a
/// full-opacity, hue-preserving highlight computed so the SELECTED TEXT stays
/// legible (>= 4.5 contrast) against it on the page, and
/// [TextSelectionThemeData.cursorColor] is the retoned accent
/// ([ColorScheme.primary]). Flutter's own [EditableText]/[SelectableText]/
/// [TextField] read those theme roles automatically, so they inherit the
/// selected-text >= 4.5 guarantee for free.
///
/// A CUSTOM editor (re_editor's `CodeEditor`, or any hand-rolled
/// [EditableText] subclass that takes its own `selectionColor`/`cursorColor`)
/// does NOT read the theme unless you wire it. Such editors MUST source their
/// selection colour from `Theme.of(context).textSelectionTheme.selectionColor`
/// (fall back to their own default when null) and their cursor from
/// `textSelectionTheme.cursorColor ?? colorScheme.primary`. Hardcoding a
/// `primary.withValues(alpha: …)` selection (a common re_editor default)
/// BYPASSES this guard: on a dark page a translucent-primary highlight leaves
/// selected text at ~2:1 — illegible — which is exactly the case the managed
/// value fixes. (The highlight's own separation from the page is best-effort:
/// "region >= 3.0 AND selected-text >= 4.5" is luminance-unsatisfiable on a
/// near-black page, so text legibility is the guarantee and region is not.)
class DeskTheme {
  DeskTheme._();

  /// Parse a '#RRGGBB' or 'RRGGBB' hex string to a [Color], or null if the
  /// input is empty or malformed.
  static Color? hexToColor(String hex) {
    if (hex.isEmpty) return null;
    final s = hex.startsWith('#') ? hex.substring(1) : hex;
    if (s.length != 6) return null;
    final val = int.tryParse('FF$s', radix: 16);
    return val != null ? Color(val) : null;
  }

  /// Resolve the Material seed colour: the [seedColorHex] when it parses, else
  /// the [_kDefaultSeed] fallback.
  static Color _resolveSeed(String seedColorHex) =>
      hexToColor(seedColorHex) ?? _kDefaultSeed;

  /// Light theme. [palette] is attached as a [ThemeExtension] (pass an app
  /// subclass to preserve its type); the remaining parameters mirror [dark].
  static ThemeData light({
    required DeskPalette palette,
    String seedColorHex = '',
    String? backgroundOverride,
    String foregroundHex = '',
    String? uiFontFamily,
    String fontFamily = '',
    double baseSize = 13,
    int weight = 400,
  }) =>
      _build(
        palette,
        Brightness.light,
        seedColorHex: seedColorHex,
        backgroundOverride: backgroundOverride,
        foregroundHex: foregroundHex,
        uiFontFamily: uiFontFamily,
        fontFamily: fontFamily,
        baseSize: baseSize,
        weight: weight,
      );

  /// Dark theme. [palette] is attached as a [ThemeExtension] (pass an app
  /// subclass to preserve its type); the remaining parameters mirror [light].
  static ThemeData dark({
    required DeskPalette palette,
    String seedColorHex = '',
    String? backgroundOverride,
    String foregroundHex = '',
    String? uiFontFamily,
    String fontFamily = '',
    double baseSize = 13,
    int weight = 400,
  }) =>
      _build(
        palette,
        Brightness.dark,
        seedColorHex: seedColorHex,
        backgroundOverride: backgroundOverride,
        foregroundHex: foregroundHex,
        uiFontFamily: uiFontFamily,
        fontFamily: fontFamily,
        baseSize: baseSize,
        weight: weight,
      );

  /// Shared builder. Resolves the colour scheme, the effective page background,
  /// and a WCAG-guarded foreground, then applies the optional host UI font.
  ///
  /// Effective background mirrors what the scaffold paints: DARK → the override,
  /// else the palette's signature [DeskPalette.background]; LIGHT → the
  /// override, else the M3 surface. (Unlike alert-log's AppTheme,
  /// whose preset background could be null and fall through to the surface in
  /// dark mode, [DeskPalette.background] is always present, so dark mode always
  /// floors on it absent an override.) Foreground guard: honour [foregroundHex]
  /// only when it is legible (>= [kMinContrast]) on that background, else — or
  /// when only the background was overridden — derive a guaranteed
  /// [contrastingOn] colour. With no overrides the M3 text colours are kept
  /// untouched. [baseSize] and [weight] are reserved for app-side text
  /// styling (see DisplayConfig) and do not alter the M3 text-theme sizes
  /// here — deliberately: the M3 text theme is CHROME (dialog titles, button
  /// labels), and these two settings size an app's own CONTENT text
  /// (a document, a table). Callers going through `buildAppearanceTheme`
  /// (`appearance_pane.dart`) get a ready-made bridge from the settings that
  /// carry these two values to a `DisplayConfig` that applies them —
  /// `AppearanceSettings.toDisplayConfig()` — instead of re-deriving this
  /// split by hand.
  ///
  /// When a background override is active the entire surface family
  /// ([ColorScheme.surface], [ColorScheme.surfaceContainerLowest] …
  /// [ColorScheme.surfaceContainerHighest], [ColorScheme.surfaceDim],
  /// [ColorScheme.surfaceBright]) is folded to match the override colour (tinted
  /// lightly with [effectiveFg] for the container variants). This prevents
  /// Cards / Dialogs / BottomSheets from keeping unrelated seed tones while text
  /// is coloured for the override background.
  ///
  /// On top of that fold, three HCT-based passes run (only when an override is
  /// active — no override leaves the M3 output completely untouched):
  ///
  ///  * **Scheme retone (Strategy C).** [ColorScheme.onSurface] /
  ///    [ColorScheme.onSurfaceVariant] are derived by HCT tone-distance to a
  ///    contrast target (7:1 / 6:1) so they are colourway-tinted yet clearly
  ///    legible, and [ColorScheme.primary] / [ColorScheme.secondary] /
  ///    [ColorScheme.tertiary] are retoned (hue-preserving) to clear the WCAG
  ///    floor on the page, with their `on*` colours re-derived for the retoned
  ///    accent. Body text still paints with the flat WCAG-guarded [effectiveFg]
  ///    (the outer guarantee); the retoned tones drive every widget that reads
  ///    the scheme roles. The semantic border role [ColorScheme.outline] is
  ///    folded too — retoned with the dual-floor [nonTextGuardOn] so a bordered
  ///    control's edge clears both floors against the page (M3's outline lands
  ///    ~w2.97 on Nord otherwise). [ColorScheme.outlineVariant] is deliberately
  ///    left alone: it is the decorative hairline role (M3-intentional low
  ///    contrast). The other `*Container` roles are left to M3 — they pair
  ///    internally correctly and their separation from the page is a widget-level
  ///    (elevation / outline) concern, not a scheme one.
  ///  * **Structural widget guards.** [SliderThemeData.inactiveTrackColor],
  ///    [DividerThemeData.color], and the Switch OFF-state track fill +
  ///    outline ([SwitchThemeData.trackColor]/[SwitchThemeData.trackOutlineColor]
  ///    resolved for the un-selected state) are guarded with the DUAL-FLOOR
  ///    [nonTextGuardOn] against the page — clearing BOTH WCAG >= [kMinContrast]
  ///    AND |APCA Lc| >= 30. WCAG alone is over-generous on dark pages, so the
  ///    folded surfaceContainerHighest / outline tones can clear 3.0 yet measure
  ///    |Lc| ~23–28 (visibly faint); the second floor forces them far enough to
  ///    read under either model. Switch ON states are untouched (the primary
  ///    pair already passes). A managed [TextSelectionThemeData.selectionColor]
  ///    (plus [TextSelectionThemeData.cursorColor] = the retoned primary) keeps
  ///    the actual selected-text colour legible (>= 4.5) — its region separation
  ///    from the page is best-effort, since "region >= 3.0 AND text >= 4.5" is
  ///    luminance-unsatisfiable on near-black pages. The attached [DeskPalette]
  ///    is replaced by [DeskPalette.guardedFor] so any widget reading a palette
  ///    role directly is legible on the page.
  ///  * **Inverse-surface fold.** [ColorScheme.inverseSurface] is derived as a
  ///    high-contrast counterpoint to the page (see [_inverseCounterpointFor]),
  ///    with [ColorScheme.onInverseSurface] tone-targeted on it and
  ///    [ColorScheme.inversePrimary] retoned against it — so SnackBars / tooltips
  ///    read against a deliberate inverse, not a leftover seed tone.
  static ThemeData _build(
    DeskPalette palette,
    Brightness brightness, {
    String seedColorHex = '',
    String? backgroundOverride,
    String foregroundHex = '',
    String? uiFontFamily,
    String fontFamily = '',
    double baseSize = 13,
    int weight = 400,
  }) {
    final seed = _resolveSeed(seedColorHex);
    // The page background override, if any (a bare/`#`-prefixed RRGGBB hex).
    final Color? bgOverride =
        backgroundOverride == null ? null : hexToColor(backgroundOverride);
    // Tone the WHOLE scheme to the brightness of the page it will actually sit
    // on. When the user pins a background override, ITS luminance — not the
    // requested light/dark mode — decides the scheme brightness, so primary,
    // secondary and the container roles are toned for that page. Without this a
    // dark override under a light-mode scheme leaves accent-coloured text
    // (section headers, links, selected chips) a dark tone on a dark page =>
    // illegible; the surface fold below only re-tones the surface roles, not the
    // accents. No override => honour the requested [brightness].
    final Brightness effBrightness = bgOverride != null
        ? ThemeData.estimateBrightnessForColor(bgOverride)
        : brightness;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: effBrightness,
    );
    final isDark = effBrightness == Brightness.dark;
    // Null scaffold in light mode lets Material keep its default (surface).
    final Color? scaffoldBg =
        isDark ? (bgOverride ?? palette.background) : bgOverride;
    // The colour the app text actually sits on.
    final Color effBg =
        bgOverride ?? (isDark ? palette.background : scheme.surface);
    // WCAG-guarded foreground (null = keep M3).
    final Color? fg = hexToColor(foregroundHex);
    final Color? effectiveFg;
    if (fg != null && isLegibleOn(fg, effBg)) {
      effectiveFg = fg;
    } else if (bgOverride != null || foregroundHex.isNotEmpty) {
      effectiveFg = contrastingOn(effBg);
    } else {
      effectiveFg = null;
    }
    // When a background override is active, fold the entire surface family to
    // match the override so Card / Dialog / BottomSheet surfaces stay consistent
    // with the page background and [onSurface] remains legible against them, then
    // HCT-retone the accent + on-surface roles (Strategy C) so they stay
    // hue-true AND clear the WCAG floor on the page, and finally derive a
    // high-contrast inverse-surface counterpoint from the override.
    //
    // Slider inactive track / divider colours and the managed text-selection
    // highlight are computed here too but applied at the WIDGET-theme level
    // below (the fold leaves surfaceContainerHighest / outlineVariant sitting
    // near the page, washing those out; guarding them scheme-wide would move
    // container surfaces, so the fix is scoped to the widgets that read them).
    ColorScheme scheme2 = scheme;
    DeskPalette effPalette = palette;
    Color? structuralTrack;
    Color? structuralLine;
    Color? selectionHighlight;
    Color? switchOffTrack;
    Color? switchOffTrackOutline;
    Color? switchOffThumb;
    if (bgOverride != null && effectiveFg != null) {
      final Color base = bgOverride;
      final Color on =
          effectiveFg; // already legible on `base` (WCAG-guarded above)
      Color tint(double a) => Color.alphaBlend(on.withValues(alpha: a), base);

      // ── B · HCT tone-targeted on-surface + accent roles ──────────────────
      // onSurface / onSurfaceVariant are derived by tone-distance to a contrast
      // target so they are hue-tinted (not flat ink) yet clear a comfortable
      // margin: 7:1 for primary body-weight content, 6:1 for the quieter
      // variant. Body text itself still paints with the flat WCAG-guarded
      // `effectiveFg` (below) — the outer guarantee — but every widget that
      // reads colorScheme.onSurface(Variant) gets the colourway-tinted tone.
      final Color onSurfaceHct = toneTargetedOn(base, chromaCap: 12, target: 7);
      final Color onSurfaceVariantHct =
          toneTargetedOn(base, chromaCap: 10, target: 6);
      // Accents retoned to clear the floor on the page while preserving hue
      // (a no-op when the page-derived scheme already makes them legible, so an
      // already-good primary keeps perfect fidelity). Their on-colours are
      // re-derived against the retoned accent so a filled button's label stays
      // legible even if the accent moved.
      final Color primaryHct = accentOn(scheme.primary, base);
      final Color secondaryHct = accentOn(scheme.secondary, base);
      final Color tertiaryHct = accentOn(scheme.tertiary, base);
      // The SEMANTIC border role. M3 folds it near the page under an override
      // (Nord lands ~w2.97), so bordered/interactive control edges reading
      // `scheme.outline` (OutlinedButton side, focus rings, socket strokes) go
      // faint. Guard it with the dual-floor non-text guard against the
      // LIGHTEST folded container (tint 0.12 = surfaceContainerHighest) — the
      // binding pair: a border clearing the nearer container tone clears the
      // page too (the walk moves away from both), where guarding vs the page
      // alone left the container pair 0.03 short on Nord. Its decorative
      // sibling `outlineVariant` is intentionally left to M3.
      final Color outlineHct = nonTextGuardOn(scheme.outline, tint(0.12));

      // ── D · inverse-surface counterpoint from the override ───────────────
      // A high-contrast surface OPPOSITE the page (SnackBar, tooltips): the
      // page hue at low chroma walked to the far tone, so it reads as a
      // deliberate inverse rather than a random seed tone. onInverseSurface is
      // tone-targeted on it (>= the 4.5 SnackBar-text need); inversePrimary is
      // the accent shown ON that surface, retoned against IT (not the page).
      final Color inverseSurfaceHct = _inverseCounterpointFor(base);
      final Color inverseOnSurfaceHct =
          toneTargetedOn(inverseSurfaceHct, chromaCap: 12, target: 7);
      final Color inversePrimaryHct = accentOn(primaryHct, inverseSurfaceHct);

      scheme2 = scheme.copyWith(
        surface: base,
        surfaceContainerLowest: base,
        surfaceContainerLow: tint(0.04),
        surfaceContainer: tint(0.06),
        surfaceContainerHigh: tint(0.09),
        surfaceContainerHighest: tint(0.12),
        surfaceDim: base,
        surfaceBright: tint(0.06),
        onSurface: onSurfaceHct,
        onSurfaceVariant: onSurfaceVariantHct,
        primary: primaryHct,
        onPrimary: contrastingOn(primaryHct),
        secondary: secondaryHct,
        onSecondary: contrastingOn(secondaryHct),
        tertiary: tertiaryHct,
        onTertiary: contrastingOn(tertiaryHct),
        outline: outlineHct,
        inverseSurface: inverseSurfaceHct,
        onInverseSurface: inverseOnSurfaceHct,
        inversePrimary: inversePrimaryHct,
      );

      // ── C · structural widget-theme guards + guarded palette ─────────────
      // Track / divider / Switch OFF socket guarded with the DUAL-FLOOR
      // [nonTextGuardOn] (WCAG >= 3.0 AND |Lc| >= 30). The single-WCAG guard let
      // these clear 3.0 while measuring |Lc| ~23–28 on dark pages (over-generous
      // WCAG); the second floor forces them far enough to read perceptually.
      //   * track  — folded surfaceContainerHighest (tint 0.12) vs page.
      //   * divider — folded outlineVariant vs page.
      //   * switch OFF fill — same surfaceContainerHighest tone as the track.
      //   * switch OFF outline — the "sunk socket" edge stroke, from the (now
      //     dual-floor-guarded) scheme.outline, so the un-toggled control is
      //     delineated rather than melting into the page.
      // Switch ON states are left to M3 (primary/onPrimary already pass).
      // Selection highlight keeps the ACTUAL selected-text colour (the
      // WCAG-guarded body `on`) legible; its region separation from the page is
      // best-effort (the "region >= 3.0 AND text >= 4.5" pair is
      // luminance-unsatisfiable near black). The attached palette is retoned so
      // any widget reading a DeskPalette role directly is legible on the page.
      structuralTrack = nonTextGuardOn(tint(0.12), base);
      structuralLine = nonTextGuardOn(scheme.outlineVariant, base);
      switchOffTrack = structuralTrack;
      switchOffTrackOutline = outlineHct;
      // The OFF thumb sits ON the guarded fill, not on the page — re-pair it
      // against the fill it actually rides (guarding the fill vs the page had
      // left thumb-vs-track at w1.6–1.8 / Lc 19–25 on the dark presets).
      switchOffThumb = nonTextGuardOn(onSurfaceVariantHct, switchOffTrack);
      selectionHighlight = selectionColorFor(base, on, primaryHct);
      effPalette = palette.guardedFor(base);
    }
    final String? appFontFamily = fontFamily.isEmpty ? null : fontFamily;
    final base = ThemeData(
      useMaterial3: true,
      brightness: effBrightness,
      fontFamily: appFontFamily,
      scaffoldBackgroundColor: scaffoldBg,
      colorScheme: scheme2,
      iconTheme: effectiveFg == null ? null : IconThemeData(color: effectiveFg),
      sliderTheme: structuralTrack == null
          ? null
          : SliderThemeData(inactiveTrackColor: structuralTrack),
      dividerTheme: structuralLine == null
          ? null
          : DividerThemeData(color: structuralLine),
      // Switch OFF-state guard: only the UN-selected state is overridden — the
      // track fill + the socket outline are pushed to the dual-floor tones so an
      // OFF switch is visible on the page. The SELECTED state resolves to null
      // so Material keeps its own ON colours (primary track / onPrimary thumb,
      // already legible). scheme2's outline is guarded too, but the OFF outline
      // needs an explicit resolver because M3 uses `outline` only in the OFF
      // state (the ON track has no outline).
      switchTheme: switchOffTrack == null
          ? null
          : SwitchThemeData(
              trackColor: WidgetStateProperty.resolveWith<Color?>(
                (states) => states.contains(WidgetState.selected)
                    ? null
                    : switchOffTrack,
              ),
              trackOutlineColor: WidgetStateProperty.resolveWith<Color?>(
                (states) => states.contains(WidgetState.selected)
                    ? null
                    : switchOffTrackOutline,
              ),
              thumbColor: WidgetStateProperty.resolveWith<Color?>(
                (states) => states.contains(WidgetState.selected)
                    ? null
                    : switchOffThumb,
              ),
            ),
      textSelectionTheme: selectionHighlight == null
          ? null
          : TextSelectionThemeData(
              selectionColor: selectionHighlight,
              // Cursor = the retoned accent. Custom editors that honour the
              // contract read this; Flutter's own fields use it directly.
              cursorColor: scheme2.primary,
            ),
      extensions: [effPalette],
    );
    // Optional host UI font — weight-split so "Cantarell Bold" resolves to its
    // base family + weight (Flutter matches base family + weight, not a
    // weight-named family).
    final (uiBase, _) = (uiFontFamily == null || uiFontFamily.isEmpty)
        ? ('', null)
        : splitFamilyWeight(uiFontFamily);
    final String? uiFam = uiBase.isEmpty ? null : uiBase;
    if (effectiveFg == null && uiFam == null) return base;
    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: uiFam,
        bodyColor: effectiveFg,
        displayColor: effectiveFg,
      ),
      primaryTextTheme:
          uiFam == null ? null : base.primaryTextTheme.apply(fontFamily: uiFam),
    );
  }
}

/// A high-contrast inverse surface for page background [page]: the page's own
/// hue at a low chroma, walked along the tone axis to the tone that maximises
/// WCAG contrast against the page. This is the [ColorScheme.inverseSurface]
/// counterpoint used by SnackBars / tooltips — a deliberate opposite of the page
/// rather than a leftover seed tone.
///
/// It scans every tone (not just the two extremes) because a mid-tone page's
/// best counterpoint may be an interior tone once chroma is fixed; the scan
/// keeps the running best. A pure black/white extreme is always a candidate, so
/// the result is at worst the [contrastingOn] of the page — meaning
/// `inverseSurface` vs `page` reaches the widest separation the hue admits, and
/// is >= [kMinContrast] for any real page (black-vs-page and white-vs-page cannot
/// both fall below 3.0). On a near-mid-grey page that widest separation is
/// modest (~4-5:1); that is the documented hard case where a stronger separation
/// is simply not reachable while staying on the page hue.
Color _inverseCounterpointFor(Color page) {
  final h = Hct.fromInt(page.toARGB32());
  final double chroma = h.chroma < 8 ? h.chroma : 8;
  // Seed the scan with the guaranteed black/white extreme so the result can
  // never be worse than contrastingOn(page).
  Color best = contrastingOn(page);
  double bestContrast = contrastRatio(best, page);
  for (int t = 0; t <= 100; t++) {
    final cand = Color(Hct.from(h.hue, chroma, t.toDouble()).toInt());
    final c = contrastRatio(cand, page);
    if (c > bestContrast) {
      bestContrast = c;
      best = cand;
    }
  }
  return best;
}
