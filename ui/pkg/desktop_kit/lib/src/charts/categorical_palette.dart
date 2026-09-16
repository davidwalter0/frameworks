// Categorical chart color assignment — "color follows the entity, never its
// rank" (dataviz skill, non-negotiable #3): each entity name (a series, an
// upstream, a seed/arm cohort, ...) is assigned the next unused slot the
// FIRST time it is seen and keeps that color for the assigning
// [CategoricalPalette] instance's lifetime, so removing a series via a
// filter never repaints the survivors.
//
// ── Provenance (READ THIS before changing the hex values) ─────────────────
// Ported from gatehub-kit/ui/ghk_dashboard's `lib/src/charts/
// categorical_palette.dart` (ghk_dashboard itself untouched — see
// chart_series.dart's library doc for the promotion note) and generalized
// for kit-wide reuse: the derivation and the hex values are IDENTICAL, since
// this kit's own [DeskPalette.standard] carries the exact same
// accent/alt/info/neutral hex ghk_dashboard's derivation started from
// (accent #9c27b0, alt #00bcd4, info #2196f3, neutral #607d8b — verified
// against desk_palette.dart's `standard` preset, this repo, 2026-08-11).
//
// The chart contract calls for DeskPalette's `accent / alt / info / neutral`
// roles, in that order, as the 4-slot categorical set. Their RAW hex values
// FAIL the dataviz skill's validator as a 4-slot categorical palette:
//   - neutral's chroma (0.04) is below the 0.10 floor — it reads as gray,
//     not a hue, so it can't carry series identity at all.
//   - alt (hue ~211°) and info (hue ~249°) sit only ~38° apart in OKLCH hue,
//     so their worst-pair ΔE is 12.6 (normal vision) / 6.0 (CVD) — below the
//     15/8 floors.
//   - alt's dark-mode lightness (L=0.729) sits above the 0.48-0.67 dark band.
// Per the skill's snap-to-passing method, each slot was re-toned — hue
// nudged, lightness/chroma moved into band — while keeping each role's
// rough hue family where the floor allowed:
//   accent (was #9c27b0, magenta/purple, H≈321°) → kept in the magenta
//     family (H≈330°): light #a840a2, dark #c95fc2.
//   alt (was #00bcd4, cyan, H≈211°) → moved to the green/teal family
//     (H≈165-180°) to clear distance from info: light #009076, dark #00af73.
//   info (was #2196f3, blue, H≈249°) → kept almost exactly (H≈255°): light
//     #026fd7, dark #348ff9.
//   neutral (was #607d8b, near-gray, H≈229°, chroma 0.04) → moved to the
//     orange family (H≈45-60°) and given real chroma: light #c14100, dark
//     #db6d00.
//
// RE-VALIDATED here (`node dataviz/scripts/validate_palette.js`, this
// promotion, 2026-08-11) rather than trusted from the ghk_dashboard comment —
// ALL CHECKS PASS, light and dark, both the default *adjacent* pairlist and
// `--pairs all` (any two of the four could be legend-toggled side by side):
//   light (surface #f9f9ff): lightness band PASS, chroma floor PASS
//     (all >= 0.10), CVD separation PASS (worst adjacent AND all-pairs
//     #009076↔#a840a2 ΔE 8.9 deutan / tritan 4.3), normal-vision floor PASS
//     (worst #026fd7↔#009076 ΔE 19.9), contrast vs surface PASS (all >= 3:1).
//   dark (surface #121212): lightness band PASS, chroma floor PASS, CVD
//     separation PASS (worst adjacent #00af73↔#c95fc2 ΔE 12.2 deutan / tritan
//     4.6; worst all-pairs #db6d00↔#00af73 ΔE 9.7 deutan / tritan 4.6),
//     normal-vision floor PASS (worst adjacent #348ff9↔#00af73 ΔE 24.4;
//     worst all-pairs #348ff9↔#c95fc2 ΔE 21.9), contrast vs surface PASS
//     (all >= 3:1).
// Full command transcripts are in this branch's session report.
library;

import 'package:flutter/material.dart';

/// Fixed hue order for light surfaces — `[accent, alt, info, neutral]`, snap-
/// to-passing derived from [DeskPalette]'s roles of the same names (see the
/// library doc above). Assign in this order; never cycle a 5th entity onto
/// slot 0 — fold extras onto the last slot instead (dataviz skill
/// non-negotiable — see [CategoricalPalette]).
const List<Color> kCategoricalLight = <Color>[
  Color(0xFFA840A2), // accent (was #9c27b0)
  Color(0xFF009076), // alt (was #00bcd4)
  Color(0xFF026FD7), // info (was #2196f3)
  Color(0xFFC14100), // neutral (was #607d8b)
];

/// Fixed hue order for dark surfaces — same slot order/identity as
/// [kCategoricalLight], stepped for the dark band (see the library doc).
const List<Color> kCategoricalDark = <Color>[
  Color(0xFFC95FC2), // accent
  Color(0xFF00AF73), // alt
  Color(0xFF348FF9), // info
  Color(0xFFDB6D00), // neutral
];

/// Returns [kCategoricalLight] or [kCategoricalDark] for the theme currently
/// active in [context].
List<Color> categoricalPaletteFor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? kCategoricalDark
        : kCategoricalLight;

/// Assigns a stable color to each entity name, first-seen order, from a
/// fixed [colors] list — the "color follows the entity" mechanism. A 5th+
/// distinct entity folds onto the LAST slot rather than cycling back to
/// slot 0 (cycling would let two different entities silently share a hue
/// identity at different times).
///
/// One instance's lifetime is the unit of stability: as long as the SAME
/// instance keeps being asked (across rebuilds, across a filter narrowing
/// the visible set), colors already handed out never change. A caller that
/// wants stability across a filter change must therefore either reuse one
/// long-lived instance, or call [colorFor] for the FULL, unfiltered entity
/// universe (in a stable, deterministic order — e.g. sorted) before reading
/// colors for whatever filtered subset it is about to render.
class CategoricalPalette {
  /// Creates a palette drawing from [colors] in fixed order.
  CategoricalPalette(this.colors) : assert(colors.isNotEmpty);

  /// The fixed, ordered hue set this palette assigns from.
  final List<Color> colors;

  final Map<String, Color> _assigned = <String, Color>{};
  int _next = 0;

  /// Returns the color assigned to [entity], assigning the next unused slot
  /// on first sight and caching it for the lifetime of this instance — a
  /// later call for a DIFFERENT entity never changes an already-assigned
  /// color, so filtering/removing series never repaints the survivors.
  Color colorFor(String entity) {
    return _assigned.putIfAbsent(entity, () {
      final int slot = _next < colors.length ? _next : colors.length - 1;
      _next++;
      return colors[slot];
    });
  }
}
