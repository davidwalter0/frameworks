// HCT (Hue-Chroma-Tone) contrast tooling — the colour-science engine promoted
// from the Contrast Lab's Strategy C prototype (`example/lib/contrast_lab/
// strategies.dart`). Where `contrast.dart`'s [contrastingOn] guarantees legibility
// by collapsing to flat black or white, these helpers guarantee legibility while
// PRESERVING THE COLOURWAY HUE: they move a colour along the HCT tone axis
// (perceived lightness) until it clears a WCAG contrast target, keeping hue and a
// capped chroma fixed. The result is a subtly tinted on-colour / accent that both
// clears the floor and still reads as "the theme's colour", instead of a
// washed-out white.
//
// ── Why tone-walking is sound ─────────────────────────────────────────────────
// In HCT, Tone is calibrated to CIE L* (perceived lightness), and WCAG relative
// luminance is a monotone function of L*. So walking Tone away from the surface's
// tone monotonically drives the WCAG contrast ratio in one direction — up when
// moving toward the opposite end of the lightness range. That makes a simple
// linear tone scan a correct search for "the nearest tone that clears the target"
// (nearest = smallest lightness shift = closest to the original colour). Chroma is
// held at a cap because HCT gamut-maps out-of-sRGB requests: at extreme tones the
// realizable chroma collapses toward 0 anyway, so a modest cap keeps the walked
// colour inside gamut and avoids hue drift from aggressive gamut mapping.
//
// ── Chroma / target policy (defaults are hand-tuned; every knob is a parameter) ─
//   * [toneTargetedOn] default chromaCap = 12, target = [kMinContrast]-plus-body
//     = 4.5. 12 is the onSurface cap; onSurfaceVariant uses a slightly lower cap
//     (10) so muted/label text stays quiet. The builder raises the *target* per
//     role (e.g. 7.0 for onSurface, 6.0 for onSurfaceVariant) because small,
//     low-emphasis text needs headroom above the bare 3.0 UI floor (the
//     size-aware APCA floors showed 4.5 is visibly short for muted labels).
//   * [accentOn] default target = 4.5 (WCAG-AA for normal text). Accents that
//     already clear the target are returned UNCHANGED (perfect hue fidelity);
//     only failing accents are retoned. Structural non-text guards call it with
//     target = [kMinContrast] (3.0), the UI-component floor.
// These defaults reproduce the lab's tuning; callers override per role.
//
// Pure Dart + standalone (imports only material_color_utilities' HCT and this
// package's WCAG primitives), so it unit-tests without a widget tree.
library;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'apca.dart';
import 'contrast.dart';

/// An on-[surface] foreground derived in HCT: keep the surface's hue at a capped
/// chroma, then walk the tone AWAY from the surface until the pair clears
/// [target] (a WCAG [contrastRatio]). The result is a subtly colourway-tinted
/// foreground that is guaranteed legible — the hue-preserving alternative to a
/// flat black/white [contrastingOn].
///
/// [chromaCap] bounds how saturated the derived colour may get (default 12; the
/// surface's own chroma is used when already lower). [target] is the minimum
/// contrast ratio to reach (default 4.5, WCAG-AA normal text).
///
/// Walk direction: if the surface tone is dark (< 50) the tone moves LIGHTER,
/// else DARKER — toward the end of the lightness range that increases contrast.
/// If the target is unreachable within gamut (e.g. a demanding target on a
/// near-mid surface), it falls back to [contrastingOn] so the return is ALWAYS
/// legible at the [kMinContrast] floor at minimum.
Color toneTargetedOn(
  Color surface, {
  double chromaCap = 12,
  double target = 4.5,
}) {
  final s = Hct.fromInt(surface.toARGB32());
  final hue = s.hue;
  final chroma = s.chroma < chromaCap ? s.chroma : chromaCap;
  final lighter = s.tone < 50;
  for (int step = 0; step <= 100; step++) {
    final tone = (lighter ? s.tone + step : s.tone - step).clamp(0.0, 100.0);
    final cand = Color(Hct.from(hue, chroma, tone).toInt());
    if (contrastRatio(cand, surface) >= target) return cand;
    if (tone <= 0.0 || tone >= 100.0) break;
  }
  return contrastingOn(surface);
}

/// Retone [accent] (keeping its hue + capped chroma) until it clears [target] on
/// [bg]; if it already clears it, [accent] is returned UNCHANGED (so an accent
/// that is already legible keeps perfect hue AND chroma fidelity).
///
/// This is the accent counterpart of [toneTargetedOn]: it preserves the accent's
/// own hue rather than the surface's. [target] defaults to 4.5 (WCAG-AA normal
/// text); structural non-text callers pass [kMinContrast] (3.0). Walk direction
/// follows the PAGE tone (lighten the accent on a dark page, darken it on a light
/// page). Unreachable target → [contrastingOn] fallback, so the return is always
/// at least [kMinContrast]-legible.
Color accentOn(Color accent, Color bg, {double target = 4.5}) {
  if (contrastRatio(accent, bg) >= target) return accent;
  final a = Hct.fromInt(accent.toARGB32());
  final lighter = Hct.fromInt(bg.toARGB32()).tone < 50;
  for (int step = 1; step <= 100; step++) {
    final tone = (lighter ? a.tone + step : a.tone - step).clamp(0.0, 100.0);
    final cand = Color(Hct.from(a.hue, a.chroma, tone).toInt());
    if (contrastRatio(cand, bg) >= target) return cand;
    if (tone <= 0.0 || tone >= 100.0) break;
  }
  return contrastingOn(bg);
}

/// A DUAL-FLOOR non-text guard for [fg] against [bg]: walk [fg]'s hue (at its
/// own capped chroma) along the HCT tone axis until the pair clears BOTH a WCAG
/// [contrastRatio] floor ([wcagFloor], default 3.0 — the UI-component floor) AND
/// an APCA magnitude floor (|[apcaLc]| >= [lcFloor], default 30 — the non-text
/// APCA floor). Returns the FIRST tone that satisfies both.
///
/// This is the non-text counterpart of [accentOn]. [accentOn] guards only the
/// WCAG ratio; on near-black pages the WCAG ratio is over-generous (it
/// over-rewards a light-on-dark pair), so a track / outline / divider can clear
/// WCAG 3.0 yet still measure |Lc| ~23–28 — visibly faint. Requiring BOTH floors
/// forces the tone far enough that the element reads under either model. Because
/// WCAG luminance and APCA Lc are both monotone in HCT Tone (see the module
/// header), the two floors are cleared by walking further in the same direction,
/// so the first tone that clears the tighter of the two clears both.
///
/// Walk direction follows the PAGE tone (lighten [fg] on a dark [bg], darken it
/// on a light [bg]) — the direction that increases contrast. Chroma is held at
/// [chromaCap] (the source chroma when already lower) so the guard stays
/// hue-true, exactly like [toneTargetedOn]/[accentOn].
///
/// UNREACHABLE case: if no in-gamut tone on the hue clears both floors (e.g. a
/// mid-grey page where the hue-locked ramp tops out below one floor), it falls
/// back to [contrastingOn]\([bg]) — the maximum-contrast black/white for the
/// page. That fallback is the widest separation obtainable and is documented as
/// the hard case; it is guaranteed to clear the WCAG floor and, for any real
/// (non-mid-grey) page, the APCA floor too.
Color nonTextGuardOn(
  Color fg,
  Color bg, {
  double wcagFloor = kMinContrast,
  double lcFloor = kApcaNonTextFloor,
  double chromaCap = 12,
}) {
  bool clears(Color c) =>
      contrastRatio(c, bg) >= wcagFloor && apcaLc(c, bg).abs() >= lcFloor;
  if (clears(fg)) return fg;
  final f = Hct.fromInt(fg.toARGB32());
  final chroma = f.chroma < chromaCap ? f.chroma : chromaCap;
  final lighter = Hct.fromInt(bg.toARGB32()).tone < 50;
  for (int step = 1; step <= 100; step++) {
    final tone = (lighter ? f.tone + step : f.tone - step).clamp(0.0, 100.0);
    final cand = Color(Hct.from(f.hue, chroma, tone).toInt());
    if (clears(cand)) return cand;
    if (tone <= 0.0 || tone >= 100.0) break;
  }
  return contrastingOn(bg);
}

/// The text-selection highlight surface for [page], hue-preserving and
/// full-opacity: walk [accent]'s hue across every tone, keep only candidates on
/// which [text] stays legible (>= [textTarget], default 4.5), and among those
/// pick the one most distinguishable from [page].
///
/// This encodes the lab's hard finding: "selection REGION >= 3.0 AND selected
/// TEXT >= [textTarget]" is luminance-unsatisfiable on near-black pages (the tone
/// window that keeps text legible and the window that separates the highlight
/// from the page do not overlap). So selected-TEXT legibility is the hard
/// guarantee; the region separation is BEST-EFFORT — we maximise it subject to
/// the text constraint. When no tone keeps the text legible at all, we fall back
/// to a translucent [contrastingOn] blend over the page.
Color selectionColorFor(
  Color page,
  Color text,
  Color accent, {
  double textTarget = 4.5,
}) {
  final a = Hct.fromInt(accent.toARGB32());
  Color? best;
  double bestRegion = -1;
  for (int t = 0; t <= 100; t++) {
    final cand = Color(Hct.from(a.hue, a.chroma, t.toDouble()).toInt());
    if (contrastRatio(text, cand) < textTarget) continue;
    final region = contrastRatio(cand, page);
    if (region > bestRegion) {
      bestRegion = region;
      best = cand;
    }
  }
  return best ??
      Color.alphaBlend(contrastingOn(page).withValues(alpha: 0.35), page);
}
