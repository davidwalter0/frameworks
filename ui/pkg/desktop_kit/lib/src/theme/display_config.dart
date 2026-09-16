// User-tunable display configuration: app-chrome + monospace font families,
// base text size, and variable-font weight. A plain value type with no
// state-management or persistence dependency — an app holds it in whatever
// store it uses and reads it to style table/body/cell text.
//
// Ported from alert-log's display_config.dart (itself trimmed from
// notekeep): the org heading-size ramp and the separate document font are not
// carried — apps that need them layer their own config on top.
library;

import 'package:flutter/material.dart';

/// Immutable display settings. An empty font string means "inherit / system
/// default" (so the config stays a value type with a trivial copyWith).
class DisplayConfig {
  /// App-chrome font (MaterialApp ThemeData.fontFamily). '' = system / host.
  final String appFont;

  /// Monospace font for base64 / hash cells. '' = the platform monospace.
  final String monoFont;

  /// Body / table text size (px).
  final double baseSize;

  /// Variable-font weight axis (100..900). Applied via FontVariation AND mapped
  /// to a discrete FontWeight (static fonts ignore the variation axis).
  final int weight;

  /// Desktop UI zoom factor; see [AppearanceSettings.uiScale] / [applyUiScale].
  /// Carried alongside the other display settings for hosts that read
  /// [DisplayConfig] as their single source of typography truth. 1.0 = no
  /// scaling.
  final double uiScale;

  /// Creates display settings; every field defaults to "inherit / system".
  const DisplayConfig({
    this.appFont = '', // system / host UI font
    this.monoFont = '', // platform monospace
    this.baseSize = 13,
    this.weight = 400,
    this.uiScale = 1.0,
  });

  /// Returns a copy with the given fields replaced; omitted fields are kept.
  DisplayConfig copyWith({
    String? appFont,
    String? monoFont,
    double? baseSize,
    int? weight,
    double? uiScale,
  }) {
    return DisplayConfig(
      appFont: appFont ?? this.appFont,
      monoFont: monoFont ?? this.monoFont,
      baseSize: baseSize ?? this.baseSize,
      weight: weight ?? this.weight,
      uiScale: uiScale ?? this.uiScale,
    );
  }

  String? get _appFamily => appFont.isEmpty ? null : appFont;
  String? get _monoFamily => monoFont.isEmpty ? null : monoFont;

  /// App-chrome font family for ThemeData (null = system default).
  String? get appFontFamily => _appFamily;

  List<FontVariation> get _wght => [FontVariation('wght', weight.toDouble())];

  /// The configured [weight] mapped to the nearest Material [FontWeight]
  /// (w100..w900). Bundled / static faces ship discrete weights and ignore
  /// `fontVariations('wght')`, so the weight control only takes effect if a
  /// concrete [FontWeight] is also set. Variable fonts honour [_wght]; static
  /// fonts honour this. Both are always applied so the slider works regardless.
  FontWeight get fontWeight {
    final idx = ((weight / 100).round() - 1).clamp(
      0,
      FontWeight.values.length - 1,
    );
    return FontWeight.values[idx];
  }

  /// Body / table-cell text style — app font, base size, selected weight.
  TextStyle get bodyStyle => TextStyle(
        fontFamily: _appFamily,
        fontSize: baseSize,
        height: 1.4,
        fontWeight: fontWeight,
        fontVariations: _wght,
      );

  /// Monospace style for base64 / hash cells — mono font, slightly smaller.
  TextStyle get monoStyle => TextStyle(
        fontFamily: _monoFamily,
        fontSize: baseSize - 1,
        height: 1.35,
        fontWeight: fontWeight,
        fontVariations: _wght,
      );
}
