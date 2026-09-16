// APCA — the Accessible Perceptual Contrast Algorithm (the WCAG-3 draft contrast
// model) — promoted verbatim from the Contrast Lab's `metrics.dart`. It is the
// PERCEPTUAL companion to the WCAG 2.x ratio in `contrast.dart`: where WCAG 2.x
// over-rewards white-on-dark and applies one flat floor regardless of text size,
// APCA weights text and background luminance differently per polarity and its
// required magnitude RISES as text gets smaller or lighter. Pure Dart, no widget
// tree, so it unit-tests headless.
//
// ── Version ──────────────────────────────────────────────────────────────────
// The math and every constant here are APCA-W3 **0.1.9** (the "SAPC-APCA" 0.1.9
// coefficient set): the sRGB→Ys exponent 2.4, the black soft-clamp
// (blkThrs 0.022 / blkClmp 1.414), the polarity exponents (normal 0.56/0.57,
// reverse 0.65/0.62), scale 1.14, loClip 0.10, loOffset 0.027, and deltaYmin
// 0.0005. These are copied faithfully from the lab and MUST NOT be "tidied" —
// APCA is a lookup-calibrated model and any change to a constant silently
// changes the reported Lc. APCA remains a draft; the tiered [apcaTextFloor]
// ladder below is an ESTIMATED simplification of the official (finer-grained,
// per-px / per-weight) readability lookup.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// APCA Lc thresholds (magnitudes). APCA is polarity-aware and its scale is NOT
/// the WCAG ratio — these are the commonly-cited "bronze" tiers.
const double kApcaBodyFloor = 60.0; // body text

/// Large / UI text APCA floor (magnitude of Lc).
const double kApcaLargeFloor = 45.0; // large / UI text

/// Minimum |Lc| for non-text / disabled elements.
const double kApcaNonTextFloor = 30.0; // min for non-text / disabled

/// Size/weight-aware minimum |Lc| for TEXT.
///
/// This is the point of APCA the single WCAG line misses: the required contrast
/// RISES as text gets smaller or lighter. ESTIMATED simplification — the
/// official APCA readability lookup is finer-grained (per-px, per-100 weight);
/// this ladder keeps its shape using the published guideline tiers
/// (Lc 90 preferred-body · 75 body-minimum · 60 large · 45 headline ·
/// 30 non-text):
///
///   <12px → 100 (effectively "don't set text this small")
///   12-13px → 90 · 14-17px → 75 · 18-23px → 60 · 24-31px → 45 · ≥32px → 30
///   bold (≥700) relaxes one tier; light (≤300) tightens one tier.
double apcaTextFloor(double px, int weight) {
  const List<double> tiers = [100, 90, 75, 60, 45, 30];
  int i;
  if (px < 12) {
    i = 0;
  } else if (px < 14) {
    i = 1;
  } else if (px < 18) {
    i = 2; // body
  } else if (px < 24) {
    i = 3; // large body / subtitle
  } else if (px < 32) {
    i = 4; // headline
  } else {
    i = 5;
  }
  if (weight >= 700) i = (i + 1).clamp(0, tiers.length - 1);
  if (weight <= 300) i = (i - 1).clamp(0, tiers.length - 1);
  return tiers[i];
}

/// APCA (APCA-W3 0.1.9 constants) lightness contrast Lc for [text] on [bg].
///
/// Range roughly -108 … +106. Positive = darker text on lighter background
/// (normal polarity); negative = lighter text on darker background (reverse).
/// Legibility is judged on the MAGNITUDE (see the floors above). Unlike the WCAG
/// ratio, APCA weights the text and background luminances differently per
/// polarity, so it does not over-reward white-on-dark the way WCAG 2.x does.
double apcaLc(Color text, Color bg) {
  // sRGB → screen luminance Ys. Flutter's modern Color components are already
  // 0..1; APCA uses a simple 2.4 power (NOT the WCAG piecewise linearization)
  // with its own luminance coefficients.
  double ys(Color c) =>
      0.2126729 * math.pow(c.r, 2.4).toDouble() +
      0.7151522 * math.pow(c.g, 2.4).toDouble() +
      0.0721750 * math.pow(c.b, 2.4).toDouble();

  // Soft-clamp near-black so tiny luminances don't blow the ratio up.
  const double blkThrs = 0.022;
  const double blkClmp = 1.414;
  double clampBlack(double y) =>
      y < blkThrs ? y + math.pow(blkThrs - y, blkClmp).toDouble() : y;

  final double txtY = clampBlack(ys(text));
  final double bgY = clampBlack(ys(bg));

  // Indistinguishable luminances → no contrast.
  const double deltaYmin = 0.0005;
  if ((bgY - txtY).abs() < deltaYmin) return 0.0;

  const double scale = 1.14;
  const double loClip = 0.1;
  const double loOffset = 0.027;

  double sapc;
  double out;
  if (bgY > txtY) {
    // Normal polarity: dark text on a light background.
    sapc = (math.pow(bgY, 0.56).toDouble() - math.pow(txtY, 0.57).toDouble()) *
        scale;
    out = sapc < loClip ? 0.0 : sapc - loOffset;
  } else {
    // Reverse polarity: light text on a dark background.
    sapc = (math.pow(bgY, 0.65).toDouble() - math.pow(txtY, 0.62).toDouble()) *
        scale;
    out = sapc > -loClip ? 0.0 : sapc + loOffset;
  }
  return out * 100.0;
}
