// WCAG contrast primitives, ported from notekeep (`theme/contrast.dart`, itself
// from voicelab). These are the guard math behind the colour-override feature:
// a text/background pair too low-contrast to tell apart must never render. Pure
// + standalone so they unit-test without a widget tree.
library;

import 'dart:math' show pow;

import 'package:flutter/material.dart';

/// WCAG relative luminance of [c] (0 = black … 1 = white), with the sRGB gamma
/// expansion, computed from the modern 0..1 colour components. Coefficients are
/// the WCAG 2.x weights (0.2126 R / 0.7152 G / 0.0722 B).
double relativeLuminance(Color c) {
  double lin(double ch) =>
      ch <= 0.03928 ? ch / 12.92 : pow((ch + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/// WCAG contrast ratio between [a] and [b], from 1.0 (identical) to 21.0
/// (black vs white). Symmetric in its arguments: `(hi + 0.05) / (lo + 0.05)`.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Minimum acceptable WCAG contrast ratio between app-text foreground and the
/// page background. 3.0 is the WCAG AA threshold for large text / UI components
/// — the floor below which a foreground/background pair stops being reliably
/// distinguishable. A foreground override is rejected below this so text can
/// never melt into the background.
const double kMinContrast = 3.0;

/// Whether [fg] is legible on [bg] — i.e. their [contrastRatio] meets
/// [kMinContrast].
bool isLegibleOn(Color fg, Color bg) => contrastRatio(fg, bg) >= kMinContrast;

/// A guaranteed-legible foreground for [bg]: black or white, whichever yields
/// the higher [contrastRatio]. The "identify the background → derive a base
/// contrast" primitive used when a chosen foreground is rejected.
Color contrastingOn(Color bg) =>
    contrastRatio(Colors.black, bg) >= contrastRatio(Colors.white, bg)
        ? Colors.black
        : Colors.white;
