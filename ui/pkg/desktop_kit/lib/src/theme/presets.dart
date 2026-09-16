// Curated theme presets + colour swatch lists for an Appearance settings pane.
// Pure data (no provider/widget deps) so it imports cleanly from both the theme
// builder and an app's settings UI. Ported from alert-log's presets
// (itself from notekeep), with [ThemePreset.palette] generalized to the base
// [DeskPalette] so any app's palette subclass fits.
library;

import 'package:flutter/material.dart';

import 'desk_palette.dart';

/// A named hex colour offered as a swatch. [hex] is a bare `RRGGBB` (no `#`);
/// an empty [hex] denotes the "default / clear" sentinel (no override).
@immutable
class NamedColor {
  /// Human-readable swatch label.
  final String name;

  /// Bare `RRGGBB` hex (no `#`); '' = the "default / clear" sentinel.
  final String hex;

  /// Creates a named swatch.
  const NamedColor(this.name, this.hex);
}

/// A named colourway: a Material [seed] for the app chrome, a signature dark
/// [bgHex] (used as the scaffold background floor in DARK mode only — light mode
/// keeps the M3 surface), and the matching [DeskPalette] for content colours.
@immutable
class ThemePreset {
  /// Human-readable colourway label.
  final String name;

  /// Material seed colour for the app chrome.
  final Color seed;

  /// Signature dark background as `RRGGBB`; '' = no forced background.
  final String bgHex; // RRGGBB, '' = no forced background (Material default)

  /// The colourway's content palette (a [DeskPalette] or app subclass).
  final DeskPalette palette;

  /// Creates a colourway preset.
  const ThemePreset(this.name, this.seed, this.bgHex, this.palette);
}

/// The built-in presets. "Default" is the original blue with the Material-tuned
/// palette and no forced background; the rest are the borrowed dark colourways
/// (Nord / Dracula / Solarized / Gruvbox).
const List<ThemePreset> kThemePresets = [
  ThemePreset('Default', Color(0xFF1565C0), '', DeskPalette.standard),
  ThemePreset('Nord', Color(0xFF81A1C1), '2E3440', DeskPalette.nord),
  ThemePreset('Dracula', Color(0xFFBD93F9), '282A36', DeskPalette.dracula),
  ThemePreset(
    'Solarized Dark',
    Color(0xFF268BD2),
    '002B36',
    DeskPalette.solarizedDark,
  ),
  ThemePreset(
    'Gruvbox Dark',
    Color(0xFF8EC07C),
    '282828',
    DeskPalette.gruvboxDark,
  ),
  ThemePreset(
    'Catppuccin Mocha',
    Color(0xFFCBA6F7),
    '1E1E2E',
    DeskPalette.catppuccinMocha,
  ),
];

/// The [ThemePreset] named [name], or the first preset (Default) as fallback.
ThemePreset presetByName(String name) => kThemePresets.firstWhere(
      (p) => p.name == name,
      orElse: () => kThemePresets.first,
    );

/// Foreground-override swatch options (app text): dark inks for light pages,
/// light tints for dark pages. Each is contrast-checked by the UI against the
/// current background and disabled when indistinguishable.
const List<NamedColor> kForegroundPresets = [
  NamedColor('Default', ''), // clear → keep M3 text colours
  NamedColor('Black', '000000'),
  NamedColor('Near-black', '212121'),
  NamedColor('Dark grey', '424242'),
  NamedColor('Grey', '616161'),
  NamedColor('Ink', '1B2B34'),
  NamedColor('Mid grey', '9E9E9E'),
  NamedColor('Light grey', 'E0E0E0'),
  NamedColor('Off-white', 'ECEFF4'),
  NamedColor('White', 'FFFFFF'),
  // Blues — dark inks for light pages, light blues for dark pages (ported from
  // voicelab). Greyed by the contrast guard when too close to the background.
  NamedColor('Strong blue', '0D47A1'),
  NamedColor('Navy', '13315C'),
  NamedColor('Medium blue', '5B8DEF'),
  NamedColor('Light blue', '9EC1F0'),
];

/// Background-override swatch options: a greyscale ramp, warm neutrals, and the
/// borrowed org darks — so the page background can be set independently AND
/// visibly in light mode (where the M3 tonal surface barely moves).
const List<NamedColor> kBackgroundPresets = [
  NamedColor('Default', ''), // clear → palette / M3 surface
  // Greyscale ramp — white → near-black.
  NamedColor('White', 'FFFFFF'),
  NamedColor('Grey 50', 'F5F5F5'),
  NamedColor('Grey 300', 'E0E0E0'),
  NamedColor('Grey 700', '616161'),
  NamedColor('Grey 850', '303030'),
  // Warm neutrals.
  NamedColor('Linen', 'FAF0E6'),
  NamedColor('Parchment', 'EFE3CF'),
  NamedColor('Tan', 'E3D2B8'),
  // Cool light + the borrowed org darks.
  NamedColor('Nord snow', 'ECEFF4'),
  NamedColor('Nord', '2E3440'),
  NamedColor('Dracula', '282A36'),
  NamedColor('Solarized Dark', '002B36'),
  NamedColor('Gruvbox Dark', '282828'),
  NamedColor('Near-black', '121212'),
  // Blues — light pages → navy (ported from voicelab). The foreground contrast
  // guard isolates any low-contrast text/background pair, including blue-on-blue.
  NamedColor('Pale blue', 'EAF2FB'),
  NamedColor('Light steel blue', 'D6E4F2'),
  NamedColor('Slate blue', '1E3A5F'),
  NamedColor('Deep navy', '0A1929'),
];
