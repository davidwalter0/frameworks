// A complete, CONTROLLED appearance-settings surface: the value type that
// captures every theme knob ([AppearanceSettings]), the pure mapping from those
// settings to a [ThemeData] ([buildAppearanceTheme]), and the widgets that edit
// them.
//
// The editing surface is split into two independent, controlled widgets so apps
// can compose appearance however their UX needs:
//   • [ThemeColorControls] — preset chips, brightness, seed / background /
//     foreground colours (foreground contrast-gated), with an optional preview;
//   • [FontControls] — app-font + mono-font pickers and the base-size + weight
//     sliders, with an optional preview and an [FontControls.extraFontFamilies]
//     hook so embedded/bundled fonts (which fc-list can't see) still appear.
// [AppearancePane] is a thin composition of both — the original all-in-one pane,
// kept for backward compatibility, now with an `extraFontFamilies` pass-through.
//
// State-management agnostic by construction: every widget here is a pure
// `StatelessWidget` driven by a `value` + `onChanged` pair (the controlled-input
// idiom). None owns mutable state, a provider, or persistence — the host app
// holds the [AppearanceSettings] in whatever store it uses and feeds edits back
// in. [AppearanceSettings] carries defensive `fromMap`/`toMap` so the host can
// persist it, but the widgets never read or write storage themselves.
//
// Builds on the rest of the theme module: [kThemePresets]/[presetByName] for
// colourways, [kBackgroundPresets]/[kForegroundPresets] for swatches, the WCAG
// [isLegibleOn] guard for contrast-gating text colours, [DeskTheme] for the
// actual theme construction, [DisplayConfig] for the live-preview text styles,
// and [systemFontFamilies]/[filterFonts] for the searchable font pickers.
library;

import 'package:flutter/material.dart';

import 'contrast.dart';
import 'desk_palette.dart';
import 'desk_theme.dart';
import 'display_config.dart';
import 'font_tools.dart';
import 'presets.dart';

/// The complete set of user-tunable appearance options, as one immutable value.
///
/// Every field has a benign default, so `const AppearanceSettings()` is the
/// "nothing overridden" state. Hex fields and font fields use `''` as the
/// "default / inherit" sentinel (matching [DeskTheme] and [DisplayConfig]).
/// Mirrors what [buildAppearanceTheme] consumes and what [AppearancePane] edits.
@immutable
class AppearanceSettings {
  /// Name of the active [ThemePreset] (see [kThemePresets]); 'Default' floors.
  final String presetName;

  /// Light / dark / follow-system selection.
  final ThemeMode mode;

  /// Material seed colour override as bare `RRGGBB`; '' = use the preset's seed.
  final String seedHex;

  /// Page background override as bare `RRGGBB`; '' = palette / M3 surface.
  final String backgroundHex;

  /// App-text foreground override as bare `RRGGBB`; '' = keep M3 text colours.
  final String foregroundHex;

  /// App-chrome / body font family; '' = system / host UI font. Unlike
  /// [monoFont]/[baseSize]/[weight] below, this DOES reach the M3 chrome:
  /// [buildAppearanceTheme] threads it into `ThemeData.fontFamily`, so
  /// dialogs, menus and buttons pick it up automatically — no bridge needed.
  final String appFont;

  /// Monospace font family for code / hash cells; '' = platform monospace.
  ///
  /// [buildAppearanceTheme] does NOT apply this — there is no "monospace"
  /// concept in an M3 [ThemeData]. It exists to feed a [DisplayConfig] (see
  /// [toDisplayConfig]) that a host uses to style its OWN monospace content
  /// (a hash cell, a code block); read it directly, or via [toDisplayConfig],
  /// wherever that content is rendered.
  final String monoFont;

  /// Body / table text size (px).
  ///
  /// [buildAppearanceTheme] does NOT thread this into `ThemeData.textTheme`
  /// — see [DeskTheme]'s builder doc for why the split (content text vs.
  /// chrome text) is deliberate. Style your app's own content text with
  /// [toDisplayConfig] (or read this field directly); the M3 `bodyMedium`
  /// size is untouched no matter what a user picks on this slider.
  final double baseSize;

  /// Variable-font weight axis (100..900).
  ///
  /// Same scope note as [baseSize]: [buildAppearanceTheme] does NOT apply
  /// this to the M3 text theme. Use [toDisplayConfig] (or read the field
  /// directly) to apply it to your app's own content text.
  final int weight;

  /// Desktop UI zoom factor applied on top of [baseSize]/text scaling; see
  /// [applyUiScale]. Valid range is 0.8..1.5; 1.0 = no scaling.
  final double uiScale;

  /// Creates appearance settings; every field defaults to "unset / inherit".
  const AppearanceSettings({
    this.presetName = 'Default',
    this.mode = ThemeMode.system,
    this.seedHex = '',
    this.backgroundHex = '',
    this.foregroundHex = '',
    this.appFont = '',
    this.monoFont = '',
    this.baseSize = 13,
    this.weight = 400,
    this.uiScale = 1.0,
  });

  /// Returns a copy with the given fields replaced; omitted fields are kept.
  AppearanceSettings copyWith({
    String? presetName,
    ThemeMode? mode,
    String? seedHex,
    String? backgroundHex,
    String? foregroundHex,
    String? appFont,
    String? monoFont,
    double? baseSize,
    int? weight,
    double? uiScale,
  }) {
    return AppearanceSettings(
      presetName: presetName ?? this.presetName,
      mode: mode ?? this.mode,
      seedHex: seedHex ?? this.seedHex,
      backgroundHex: backgroundHex ?? this.backgroundHex,
      foregroundHex: foregroundHex ?? this.foregroundHex,
      appFont: appFont ?? this.appFont,
      monoFont: monoFont ?? this.monoFont,
      baseSize: baseSize ?? this.baseSize,
      weight: weight ?? this.weight,
      uiScale: uiScale ?? this.uiScale,
    );
  }

  /// Serialises to a JSON-friendly map (enum stored by `.name`) for persistence.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'presetName': presetName,
        'mode': mode.name,
        'seedHex': seedHex,
        'backgroundHex': backgroundHex,
        'foregroundHex': foregroundHex,
        'appFont': appFont,
        'monoFont': monoFont,
        'baseSize': baseSize,
        'weight': weight,
        'uiScale': uiScale,
      };

  /// Rebuilds settings from a (possibly malformed) persisted map.
  ///
  /// Defensive: a non-map input, missing keys, or wrong-typed values fall back
  /// to the corresponding default rather than throwing — so a corrupt or
  /// partial config file never crashes the app.
  factory AppearanceSettings.fromMap(Object? raw) {
    if (raw is! Map) return const AppearanceSettings();
    const AppearanceSettings d = AppearanceSettings();
    String str(String key, String fallback) {
      final Object? v = raw[key];
      return v is String ? v : fallback;
    }

    double dbl(String key, double fallback) {
      final Object? v = raw[key];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    int integer(String key, int fallback) {
      final Object? v = raw[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    // Only accepts a numeric value (any other type, including a malformed
    // string, falls back to the default); the result is always clamped into
    // the valid [0.8, 1.5] range so an out-of-range persisted value can never
    // leak through unclamped.
    double clampedUiScale(String key, double fallback) {
      final Object? v = raw[key];
      final double parsed = v is num ? v.toDouble() : fallback;
      return parsed.clamp(0.8, 1.5).toDouble();
    }

    final Object? modeName = raw['mode'];
    final ThemeMode mode = ThemeMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => d.mode,
    );
    return AppearanceSettings(
      presetName: str('presetName', d.presetName),
      mode: mode,
      seedHex: str('seedHex', d.seedHex),
      backgroundHex: str('backgroundHex', d.backgroundHex),
      foregroundHex: str('foregroundHex', d.foregroundHex),
      appFont: str('appFont', d.appFont),
      monoFont: str('monoFont', d.monoFont),
      baseSize: dbl('baseSize', d.baseSize),
      weight: integer('weight', d.weight),
      uiScale: clampedUiScale('uiScale', d.uiScale),
    );
  }

  /// Bridges to a [DisplayConfig] for styling an app's own CONTENT text (a
  /// buffer, a table cell, a code block) — [monoFont], [baseSize] and
  /// [weight] are the fields [buildAppearanceTheme] does NOT thread into the
  /// M3 chrome theme it builds (see those fields' docs), plus [appFont] and
  /// [uiScale] so a host has one call for everything instead of two sources
  /// of truth.
  ///
  /// A straight field-for-field copy — every value round-trips unchanged
  /// into the identically-named [DisplayConfig] field — kept as ONE method
  /// so the bridge from "the user's Fonts settings" to "text the app
  /// actually paints" is a single call, not four fields copied by hand at
  /// every call site (this file's own [_Preview] used to do exactly that;
  /// it now calls this instead) and silently allowed to drift as fields are
  /// added to one type and not the other.
  DisplayConfig toDisplayConfig() => DisplayConfig(
        appFont: appFont,
        monoFont: monoFont,
        baseSize: baseSize,
        weight: weight,
        uiScale: uiScale,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceSettings &&
          other.presetName == presetName &&
          other.mode == mode &&
          other.seedHex == seedHex &&
          other.backgroundHex == backgroundHex &&
          other.foregroundHex == foregroundHex &&
          other.appFont == appFont &&
          other.monoFont == monoFont &&
          other.baseSize == baseSize &&
          other.weight == weight &&
          other.uiScale == uiScale;

  @override
  int get hashCode => Object.hash(
        presetName,
        mode,
        seedHex,
        backgroundHex,
        foregroundHex,
        appFont,
        monoFont,
        baseSize,
        weight,
        uiScale,
      );
}

/// Maps [AppearanceSettings] to a concrete [ThemeData] for the given
/// [brightness], delegating to [DeskTheme.light]/[DeskTheme.dark].
///
/// The palette is [palette] when supplied, else the named preset's palette.
/// The seed is [AppearanceSettings.seedHex] when set, else the named preset's
/// signature seed — so selecting a colourway re-tints the M3 chrome even with
/// no explicit seed override. The remaining empty-string sentinels are
/// translated to [DeskTheme]'s conventions (empty foreground → defaults; empty
/// background → null = no override). Pure: no context, no side effects — call
/// it from any state-management layer. The caller is responsible for resolving
/// [ThemeMode.system] to a concrete [Brightness] (e.g. from
/// `MediaQuery.platformBrightnessOf`) before calling.
///
/// SCOPE — read this before assuming every [AppearanceSettings] field is "in"
/// the returned theme: this builds the M3 CHROME theme only.
/// [AppearanceSettings.appFont] reaches it (`ThemeData.fontFamily`), but
/// [AppearanceSettings.monoFont], [AppearanceSettings.baseSize],
/// [AppearanceSettings.weight] and [AppearanceSettings.uiScale] do not — they
/// style an app's own CONTENT text and are not reflected in the returned
/// [ThemeData.textTheme] at all. That is deliberate (see [DeskTheme]'s
/// builder doc: the "Base size" slider is meant to resize a document/table's
/// own text, not a dialog's title), not an oversight — call
/// [AppearanceSettings.toDisplayConfig] to apply those fields to your
/// content text, and [applyUiScale] to apply [AppearanceSettings.uiScale].
ThemeData buildAppearanceTheme(
  AppearanceSettings s,
  Brightness brightness, {
  DeskPalette? palette,
}) {
  final ThemePreset preset = presetByName(s.presetName);
  final DeskPalette pal = palette ?? preset.palette;
  // Fall back to the preset's signature seed when the user has not picked an
  // explicit seed override — mirroring the palette fallback above. Without
  // this, selecting a colourway re-tints only the semantic palette (and, in
  // dark mode, the background), while the M3 chrome accent — the very colour
  // the preset chip's avatar advertises — silently stays the default seed.
  final String seedHex =
      s.seedHex.isNotEmpty ? s.seedHex : _hexFromColor(preset.seed);
  // Likewise the preset's signature BACKGROUND: with no explicit override the
  // preset's bgHex applies, so selecting a colourway moves the page — and
  // triggers DeskTheme's surface-family fold + page-derived brightness — in
  // light mode too, not only via palette.background in dark mode. Explicit
  // user overrides still win; a preset with no bgHex ('' — Default) leaves
  // the M3 surface untouched.
  final String? bg = s.backgroundHex.isNotEmpty
      ? s.backgroundHex
      : (preset.bgHex.isEmpty ? null : preset.bgHex);
  if (brightness == Brightness.dark) {
    return DeskTheme.dark(
      palette: pal,
      seedColorHex: seedHex,
      backgroundOverride: bg,
      foregroundHex: s.foregroundHex,
      fontFamily: s.appFont,
      baseSize: s.baseSize,
      weight: s.weight,
    );
  }
  return DeskTheme.light(
    palette: pal,
    seedColorHex: seedHex,
    backgroundOverride: bg,
    foregroundHex: s.foregroundHex,
    fontFamily: s.appFont,
    baseSize: s.baseSize,
    weight: s.weight,
  );
}

/// Bare `RRGGBB` hex (no `#`) for [c] — the format [DeskTheme.hexToColor]
/// round-trips.
String _hexFromColor(Color c) =>
    (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// A curated set of Material seed colours offered as quick swatches, plus the
/// leading "Default" sentinel ('' hex) that clears any seed override (falling
/// back to the active preset's seed). Small and self-contained so the pane needs
/// no external seed list.
const List<NamedColor> kSeedPresets = [
  NamedColor('Default', ''), // clear → preset seed
  NamedColor('Blue', '1565C0'),
  NamedColor('Indigo', '3F51B5'),
  NamedColor('Teal', '009688'),
  NamedColor('Green', '2E7D32'),
  NamedColor('Lime', '827717'),
  NamedColor('Amber', 'FF8F00'),
  NamedColor('Orange', 'EF6C00'),
  NamedColor('Deep orange', 'D84315'),
  NamedColor('Red', 'C62828'),
  NamedColor('Pink', 'AD1457'),
  NamedColor('Purple', '6A1B9A'),
  NamedColor('Brown', '5D4037'),
  NamedColor('Blue grey', '455A64'),
];

// ── Shared brightness / effective-background maths ────────────────────────────

/// Resolve [mode] against the ambient platform brightness so previews and the
/// contrast gate reflect what 'System' would actually paint. Shared by
/// [ThemeColorControls], [FontControls], and [AppearancePane].
Brightness _resolveBrightness(BuildContext context, ThemeMode mode) =>
    switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };

/// The colour app text actually sits on — mirrors [DeskTheme]'s `effBg`: the
/// background override if set, else the preset palette background in dark mode,
/// else the seeded M3 surface in light mode. Used to contrast-gate the
/// foreground swatches and to back the live previews.
Color _effectiveBackgroundFor(BuildContext context, AppearanceSettings value) {
  final Color? override = value.backgroundHex.isEmpty
      ? null
      : DeskTheme.hexToColor(value.backgroundHex);
  if (override != null) return override;
  final ThemePreset preset = presetByName(value.presetName);
  final Brightness b = _resolveBrightness(context, value.mode);
  if (b == Brightness.dark) return preset.palette.background;
  final Color seed = DeskTheme.hexToColor(value.seedHex) ?? preset.seed;
  return ColorScheme.fromSeed(seedColor: seed, brightness: b).surface;
}

// ── ThemeColorControls — colourway half ───────────────────────────────────────

/// The theming / colour half of the appearance surface: preset chips,
/// brightness, and the seed / background / foreground colour swatches (the
/// foreground row contrast-gated by the WCAG guard), with an optional colour
/// preview.
///
/// Fully controlled (renders [value], reports edits via [onChanged] as
/// `value.copyWith(...)`) and state-management agnostic. Edits only the
/// colour/brightness fields of [AppearanceSettings]; it never touches the font,
/// size, or weight fields, so an app can pair it with [FontControls] — or its
/// own font UI — independently. Scrollable-friendly (`MainAxisSize.min`), so it
/// drops into a page, dialog, or bottom sheet unchanged.
class ThemeColorControls extends StatelessWidget {
  /// Creates the controlled theming/colour controls.
  const ThemeColorControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.showPreview = true,
  });

  /// The current settings to render (only colour fields are read/edited here).
  final AppearanceSettings value;

  /// Called with the updated settings whenever a colour control changes.
  final ValueChanged<AppearanceSettings> onChanged;

  /// Whether to render the colour preview block at the bottom.
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    final Color effBg = _effectiveBackgroundFor(context, value);
    final Brightness b = _resolveBrightness(context, value.mode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SectionLabel('Preset'),
        const SizedBox(height: 6),
        _PresetChips(
          selected: value.presetName,
          onSelect: (ThemePreset p) {
            // Adopt the preset's signature dark background when in dark mode,
            // mirroring the donor apps' behaviour, so a dark preset looks right.
            final String bg = (b == Brightness.dark && p.bgHex.isNotEmpty)
                ? p.bgHex
                : value.backgroundHex;
            onChanged(value.copyWith(presetName: p.name, backgroundHex: bg));
          },
        ),
        const SizedBox(height: 16),
        const _SectionLabel('Brightness'),
        const SizedBox(height: 6),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text('System'),
              icon: Icon(Icons.brightness_auto_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text('Light'),
              icon: Icon(Icons.light_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text('Dark'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: {value.mode},
          onSelectionChanged: (Set<ThemeMode> s) {
            if (s.isNotEmpty) onChanged(value.copyWith(mode: s.first));
          },
        ),
        const SizedBox(height: 16),
        const _SectionLabel('Seed colour'),
        const SizedBox(height: 6),
        _SwatchRow(
          swatches: kSeedPresets,
          selected: value.seedHex,
          onSelect: (String hex) => onChanged(value.copyWith(seedHex: hex)),
        ),
        const SizedBox(height: 16),
        const _SectionLabel('Background'),
        const SizedBox(height: 6),
        _SwatchRow(
          swatches: kBackgroundPresets,
          selected: value.backgroundHex,
          onSelect: (String hex) =>
              onChanged(value.copyWith(backgroundHex: hex)),
        ),
        const SizedBox(height: 16),
        const _SectionLabel('Text colour'),
        const SizedBox(height: 6),
        _ForegroundSwatchRow(
          selected: value.foregroundHex,
          effectiveBackground: effBg,
          onSelect: (String hex) =>
              onChanged(value.copyWith(foregroundHex: hex)),
        ),
        if (showPreview) ...[
          const SizedBox(height: 16),
          const _SectionLabel('Live preview'),
          const SizedBox(height: 6),
          _Preview(settings: value, background: effBg),
        ],
      ],
    );
  }
}

// ── FontControls — typography half ────────────────────────────────────────────

/// The typography half of the appearance surface: the app-font and mono-font
/// pickers plus the base-size and weight sliders, with an optional preview.
///
/// Fully controlled (renders [value], reports edits via [onChanged] as
/// `value.copyWith(...)`) and state-management agnostic. Edits only the font,
/// size, and weight fields, so an app can pair it with [ThemeColorControls] — or
/// its own colour UI — independently.
///
/// FOR EMBEDDING HOSTS: [AppearanceSettings.appFont] is the only field edited
/// here that [buildAppearanceTheme] applies to the M3 chrome theme. The
/// mono-font picker and the base-size/weight sliders edit fields
/// ([AppearanceSettings.monoFont]/[baseSize]/[weight]) that
/// [buildAppearanceTheme] leaves untouched by design — they style an app's
/// own content text, not its chrome (see [DeskTheme]'s builder doc). Call
/// [AppearanceSettings.toDisplayConfig] and apply the result to your content
/// text, or these three controls will visibly move while nothing in the app
/// changes.
///
/// [extraFontFamilies] is **prepended** to the families discovered by
/// [systemFontFamilies] (fc-list on Linux, a curated fallback elsewhere) before
/// the picker filters them. Use it to surface fonts fc-list cannot see — fonts
/// the app *bundles* (declared under `flutter: fonts:` in pubspec) or embeds at
/// runtime — so they are still selectable. Names are de-duplicated
/// case-insensitively against the enumerated set, keeping the extras first.
class FontControls extends StatelessWidget {
  /// Creates the controlled font controls.
  const FontControls({
    super.key,
    required this.value,
    required this.onChanged,
    this.extraFontFamilies = const <String>[],
    this.showPreview = true,
  });

  /// The current settings to render (only font/size/weight fields are used).
  final AppearanceSettings value;

  /// Called with the updated settings whenever a font control changes.
  final ValueChanged<AppearanceSettings> onChanged;

  /// Extra families prepended to the fc-list results in BOTH pickers, so
  /// bundled/embedded fonts (invisible to fc-list) are still offered.
  final List<String> extraFontFamilies;

  /// Whether to render the typography preview block at the bottom.
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    final Color effBg = _effectiveBackgroundFor(context, value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SectionLabel('App font'),
        const SizedBox(height: 6),
        _FontField(
          family: value.appFont,
          dialogTitle: 'App font',
          extraFontFamilies: extraFontFamilies,
          onChanged: (String f) => onChanged(value.copyWith(appFont: f)),
        ),
        const SizedBox(height: 16),
        const _SectionLabel('Mono font'),
        const SizedBox(height: 6),
        _FontField(
          family: value.monoFont,
          dialogTitle: 'Monospace font',
          extraFontFamilies: extraFontFamilies,
          onChanged: (String f) => onChanged(value.copyWith(monoFont: f)),
        ),
        const SizedBox(height: 16),
        _SectionLabel('Base size — ${value.baseSize.round()} px'),
        Slider(
          value: value.baseSize.clamp(10, 20),
          min: 10,
          max: 20,
          divisions: 10,
          label: '${value.baseSize.round()} px',
          onChanged: (double v) =>
              onChanged(value.copyWith(baseSize: v.roundToDouble())),
        ),
        _SectionLabel('Weight — ${value.weight}'),
        Slider(
          value: value.weight.toDouble().clamp(100, 900),
          min: 100,
          max: 900,
          divisions: 8,
          label: '${value.weight}',
          onChanged: (double v) => onChanged(value.copyWith(weight: v.round())),
        ),
        _SectionLabel('UI scale — ${(value.uiScale * 100).round()}%'),
        Slider(
          value: value.uiScale.clamp(0.8, 1.5),
          min: 0.8,
          max: 1.5,
          divisions: 14,
          label: '${(value.uiScale * 100).round()}%',
          onChanged: (double v) => onChanged(value.copyWith(uiScale: v)),
        ),
        if (showPreview) ...[
          const SizedBox(height: 16),
          const _SectionLabel('Live preview'),
          const SizedBox(height: 6),
          _Preview(settings: value, background: effBg),
        ],
      ],
    );
  }
}

/// A fully-controlled appearance-settings editor exposing EVERY option:
/// preset, brightness, seed / background / foreground colours, app + mono fonts,
/// base size, weight, and an optional live preview.
///
/// A thin composition of [ThemeColorControls] (the colourway half) and
/// [FontControls] (the typography half) — the original all-in-one pane, kept for
/// backward compatibility. The single [showPreview] flag controls one combined
/// preview shown once at the bottom (the two halves render with preview
/// suppressed). [extraFontFamilies] is forwarded to [FontControls].
///
/// Controlled-input idiom: it renders [value] and reports edits through
/// [onChanged] (always `value.copyWith(...)`), holding no internal state. The
/// host owns the [AppearanceSettings] and decides whether/how to persist it.
/// State-management agnostic — usable from Riverpod, provider, a plain
/// [ChangeNotifier], or `setState`. Scrollable and wrap-friendly so it drops
/// into a page, an [AlertDialog], or a bottom sheet unchanged.
class AppearancePane extends StatelessWidget {
  /// Creates a controlled appearance pane.
  const AppearancePane({
    super.key,
    required this.value,
    required this.onChanged,
    this.extraFontFamilies = const <String>[],
    this.showPreview = true,
  });

  /// The current settings to render.
  final AppearanceSettings value;

  /// Called with the updated settings whenever any control changes.
  final ValueChanged<AppearanceSettings> onChanged;

  /// Extra families prepended to the fc-list results in the font pickers (see
  /// [FontControls.extraFontFamilies]).
  final List<String> extraFontFamilies;

  /// Whether to render the (single, combined) live preview block at the bottom.
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    final Color effBg = _effectiveBackgroundFor(context, value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Colour half — its own preview suppressed; the pane shows one below.
        ThemeColorControls(
          value: value,
          onChanged: onChanged,
          showPreview: false,
        ),
        const SizedBox(height: 16),
        // Typography half — likewise preview-suppressed here.
        FontControls(
          value: value,
          onChanged: onChanged,
          extraFontFamilies: extraFontFamilies,
          showPreview: false,
        ),
        if (showPreview) ...[
          const SizedBox(height: 16),
          const _SectionLabel('Live preview'),
          const SizedBox(height: 6),
          _Preview(settings: value, background: effBg),
        ],
      ],
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.title);
  final String title;

  @override
  Widget build(BuildContext context) =>
      Text(title, style: Theme.of(context).textTheme.labelLarge);
}

// ── Preset chips ──────────────────────────────────────────────────────────────

class _PresetChips extends StatelessWidget {
  const _PresetChips({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<ThemePreset> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final ThemePreset p in kThemePresets)
          ChoiceChip(
            label: Text(p.name),
            selected: selected == p.name,
            selectedColor: p.seed.withValues(alpha: 0.35),
            avatar: CircleAvatar(backgroundColor: p.seed, radius: 7),
            onSelected: (_) => onSelect(p),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

// ── Colour swatch row ─────────────────────────────────────────────────────────

class _SwatchRow extends StatelessWidget {
  const _SwatchRow({
    required this.swatches,
    required this.selected,
    required this.onSelect,
  });
  final List<NamedColor> swatches;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final NamedColor nc in swatches)
          _Swatch(
            nc: nc,
            isSelected: selected == nc.hex,
            onTap: () => onSelect(nc.hex),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.nc,
    required this.isSelected,
    required this.onTap,
    this.enabled = true,
  });
  final NamedColor nc;
  final bool isSelected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color? fill = nc.hex.isEmpty ? null : DeskTheme.hexToColor(nc.hex);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: enabled
          ? (nc.hex.isEmpty ? '${nc.name} (clear)' : '${nc.name} • #${nc.hex}')
          : '${nc.name} — low contrast on current background',
      child: Opacity(
        opacity: enabled ? 1.0 : 0.35,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: fill ?? cs.surface,
              border: Border.all(
                color: isSelected ? cs.primary : cs.outline,
                width: isSelected ? 2.5 : 0.5,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
            child: nc.hex.isEmpty
                ? Icon(Icons.close, size: 12, color: cs.onSurface)
                : null,
          ),
        ),
      ),
    );
  }
}

// ── Foreground swatch row — contrast-gated ────────────────────────────────────

class _ForegroundSwatchRow extends StatelessWidget {
  const _ForegroundSwatchRow({
    required this.selected,
    required this.effectiveBackground,
    required this.onSelect,
  });
  final String selected;
  final Color effectiveBackground;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final NamedColor nc in kForegroundPresets)
          Builder(
            builder: (BuildContext _) {
              // The "Default" sentinel is always selectable (it clears the
              // override); a concrete colour is gated by the WCAG guard.
              final Color? fg =
                  nc.hex.isEmpty ? null : DeskTheme.hexToColor(nc.hex);
              final bool enabled =
                  fg == null || isLegibleOn(fg, effectiveBackground);
              return _Swatch(
                nc: nc,
                isSelected: selected == nc.hex,
                enabled: enabled,
                onTap: () => onSelect(nc.hex),
              );
            },
          ),
      ],
    );
  }
}

// ── Font field + searchable picker dialog ─────────────────────────────────────

class _FontField extends StatelessWidget {
  const _FontField({
    required this.family,
    required this.dialogTitle,
    required this.onChanged,
    this.extraFontFamilies = const <String>[],
  });

  /// Current family ('' = system default).
  final String family;
  final String dialogTitle;
  final ValueChanged<String> onChanged;

  /// Extra families prepended to the picker's fc-list results.
  final List<String> extraFontFamilies;

  Future<void> _pick(BuildContext context) async {
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _FontPickerDialog(
        title: dialogTitle,
        current: family,
        extraFontFamilies: extraFontFamilies,
      ),
    );
    // null = dismissed (no change); the sentinel '' = "Default" chosen.
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool isDefault = family.isEmpty;
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outline),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              isDefault ? 'System default' : family,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: isDefault ? null : family,
                fontStyle: isDefault ? FontStyle.italic : FontStyle.normal,
                color: isDefault ? cs.onSurfaceVariant : cs.onSurface,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _pick(context),
          icon: const Icon(Icons.search, size: 18),
          label: const Text('Pick…'),
        ),
      ],
    );
  }
}

/// Modal font picker. Pops the chosen family on selection (the '' sentinel for
/// "Default / system"), or null when dismissed. Loads families off-isolate via
/// [systemFontFamilies], PREPENDS [extraFontFamilies] (so bundled/embedded fonts
/// fc-list can't see are still offered), then filters with [filterFonts] per
/// keystroke.
class _FontPickerDialog extends StatefulWidget {
  const _FontPickerDialog({
    required this.title,
    required this.current,
    this.extraFontFamilies = const <String>[],
  });
  final String title;
  final String current;
  final List<String> extraFontFamilies;

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  late final Future<List<String>> _families = _load();
  final TextEditingController _query = TextEditingController();
  String _q = '';

  /// Enumerate system fonts, then prepend the caller's extras (de-duplicated
  /// case-insensitively, extras kept first) so bundled/embedded fonts appear
  /// even though fc-list — the only enumeration source — cannot see them.
  Future<List<String>> _load() async {
    final List<String> system = await systemFontFamilies();
    if (widget.extraFontFamilies.isEmpty) return system;
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final String f in <String>[...widget.extraFontFamilies, ...system]) {
      final String t = f.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search fonts…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (String v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: _families,
                builder:
                    (BuildContext ctx, AsyncSnapshot<List<String>> snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final List<String> shown = filterFonts(snapshot.data!, _q);
                  return ListView(
                    children: [
                      // Always offer "Default / system" first (clears override).
                      ListTile(
                        dense: true,
                        leading: widget.current.isEmpty
                            ? const Icon(Icons.check)
                            : const SizedBox(width: 24),
                        title: const Text(
                          'System default',
                          style: TextStyle(fontStyle: FontStyle.italic),
                        ),
                        onTap: () => Navigator.of(ctx).pop(''),
                      ),
                      const Divider(height: 1),
                      for (final String f in shown)
                        ListTile(
                          dense: true,
                          leading: f == widget.current
                              ? const Icon(Icons.check)
                              : const SizedBox(width: 24),
                          title: Text(f, style: TextStyle(fontFamily: f)),
                          onTap: () => Navigator.of(ctx).pop(f),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ── Live preview ──────────────────────────────────────────────────────────────

class _Preview extends StatelessWidget {
  const _Preview({required this.settings, required this.background});
  final AppearanceSettings settings;
  final Color background;

  @override
  Widget build(BuildContext context) {
    // The same bridge a host uses to style its own content text — see
    // [AppearanceSettings.toDisplayConfig]. Using it here too (rather than
    // constructing a [DisplayConfig] by hand) is what keeps this preview
    // honest: it renders through the one supported path, not a shortcut that
    // could quietly diverge from it.
    final DisplayConfig display = settings.toDisplayConfig();
    // Foreground: the chosen override when legible, else a guaranteed-contrast
    // ink/white — so the preview never renders invisible text.
    final Color? fg = settings.foregroundHex.isEmpty
        ? null
        : DeskTheme.hexToColor(settings.foregroundHex);
    final Color text = (fg != null && isLegibleOn(fg, background))
        ? fg
        : contrastingOn(background);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The quick brown fox jumps over the lazy dog.',
            style: display.bodyStyle.copyWith(color: text),
          ),
          const SizedBox(height: 8),
          Text(
            'const sha = 0xDEADBEEF; // mono 0123456789',
            style: display.monoStyle.copyWith(color: text),
          ),
        ],
      ),
    );
  }
}
