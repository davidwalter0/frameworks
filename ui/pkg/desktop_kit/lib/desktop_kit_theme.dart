/// Theming: the WCAG contrast guard, the APCA (WCAG-3 draft) perceptual metric
/// and its size/weight-aware floors ([apcaLc]/[apcaTextFloor]), the HCT
/// hue-preserving contrast engine ([toneTargetedOn]/[accentOn]/[nonTextGuardOn]/
/// [selectionColorFor] and [DeskPalette.guardedFor]) that guarantees legibility
/// WITHOUT flattening a colourway to black/white — including the dual-floor
/// (WCAG + APCA) [nonTextGuardOn] for structural non-text roles, font tooling
/// (fc-list enumeration +
/// `splitFamilyWeight`), host-font detection (GNOME `gsettings`), the
/// [DeskPalette] [ThemeExtension] base class, the [DeskTheme] builder, the
/// [DisplayConfig] value type, the presets/swatches, and the controlled
/// appearance surface — [AppearanceSettings], [buildAppearanceTheme], and the
/// editors [AppearancePane], [ThemeColorControls] (colour half), and
/// [FontControls] (typography half, with an `extraFontFamilies` hook for
/// bundled/embedded fonts). The two halves are independently usable so an app
/// can decouple its colour and font settings. [applyUiScale] wires
/// [AppearanceSettings.uiScale] into a running tree (pragmatic text/icon zoom,
/// via `MaterialApp.builder`); [AppearanceSettings.toDisplayConfig] bridges
/// the font/size/weight fields [buildAppearanceTheme] does NOT apply (they
/// style content text, not chrome — see [DeskTheme]'s builder doc) to a
/// [DisplayConfig] for an app's own content text.
///
/// State-management agnostic: no Riverpod/provider, no flex_color_scheme, no
/// package_info_plus. Pure functions and plain classes only, so apps on any (or
/// no) state-management library can consume it.
///
/// Donor: alert-log `lib/core/theme` + `lib/core/services`
/// (font_tools, host_ui_font), generalized so notekeep's OrgPalette and
/// alert-log's NotifPalette both subclass [DeskPalette].
library;

export 'src/theme/apca.dart';
export 'src/theme/appearance_pane.dart';
export 'src/theme/contrast.dart';
export 'src/theme/desk_palette.dart';
export 'src/theme/desk_theme.dart';
export 'src/theme/display_config.dart';
export 'src/theme/font_tools.dart';
export 'src/theme/hct_tools.dart';
export 'src/theme/host_ui_font.dart';
export 'src/theme/presets.dart';
export 'src/theme/ui_scale.dart';
