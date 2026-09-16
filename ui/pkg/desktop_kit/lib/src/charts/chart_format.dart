// PURE formatting helpers shared by the chart widgets — no BuildContext, so
// directly unit-testable. Promoted from gatehub-kit/ui/ghk_dashboard's
// identical file (see chart_series.dart's library doc for the provenance
// note); unchanged except for [formatOrdinalTick], added here for
// [ChartXAxisKind.ordinal] support.
library;

import 'dart:math' as math;

/// Rounds [v] up to a "nice" number (1/2/5 × a power of ten) — the y-axis
/// tick contract ("round to clean numbers").
double niceCeil(double v) {
  if (v <= 0) return 1;
  final double exp = (math.log(v) / math.ln10).floorToDouble();
  final double base = math.pow(10, exp).toDouble();
  final double frac = v / base;
  final double niceFrac =
      frac <= 1 ? 1 : (frac <= 2 ? 2 : (frac <= 5 ? 5 : 10));
  return niceFrac * base;
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Formats [t] for an axis tick, choosing a compact `HH:mm` form when the
/// chart spans a day or less, else `MM/DD` — "sparse human ticks".
String formatAxisTick(DateTime t, Duration span) {
  if (span <= const Duration(days: 1)) {
    return '${_two(t.hour)}:${_two(t.minute)}';
  }
  return '${_two(t.month)}/${_two(t.day)}';
}

/// Formats [t] for the crosshair tooltip header — always includes both date
/// and time, since the tooltip is the "full detail" surface.
String formatTooltipTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// Formats an [ChartXAxisKind.ordinal] axis tick — the rounded integer
/// itself (a generation number, a step index, ...). A separate function
/// (rather than overloading [formatAxisTick]) because an ordinal tick needs
/// no span-dependent branching at all.
String formatOrdinalTick(double x) => x.round().toString();
