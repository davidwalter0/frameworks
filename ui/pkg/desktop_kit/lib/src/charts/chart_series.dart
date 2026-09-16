// The chart engine's data model — deliberately decoupled from any specific
// data source (VictoriaLogs, Prometheus, a JSONL fixture, ...) so
// [LineChart]/[SmallMultiples]/[StateStrip] and their tests never need a
// source-specific fixture, only plain points.
//
// ── Provenance ───────────────────────────────────────────────────────────
// Generalized from gatehub-kit/ui/ghk_dashboard's hand-rolled chart engine
// (lib/src/charts/{chart_series,chart_format,line_chart,state_strip,
// categorical_palette}.dart — the house convention: a CustomPainter per
// series, zero external charting-package dependency). ghk_dashboard itself
// is untouched by this promotion; this is a copy, generalized here to carry
// an ORDINAL x-axis (e.g. a generation number) alongside the original time
// axis — see [ChartXAxisKind].
//
// [ChartPoint]/[ChartSeries] import only `dart:ui`'s [Color] — a plain
// immutable value type, not a widget — so both stay constructible and
// comparable with no rendering pipeline, i.e. "headlessly testable" in the
// same sense beacon_monitor's `AppearanceSettings` doc uses for a value type
// that pulls in a Flutter-adjacent type without depending on the widget
// tree or [BuildContext].
library;

import 'dart:ui' show Color;

import 'package:meta/meta.dart';

/// What a [ChartPoint.x] value means, and therefore how a chart should
/// format its x-axis ticks and locate the nearest point under the pointer.
enum ChartXAxisKind {
  /// [ChartPoint.x] is `DateTime.millisecondsSinceEpoch` as a double —
  /// ticks format as clock time or calendar date depending on the span
  /// (see [formatAxisTick] in `chart_format.dart`).
  time,

  /// [ChartPoint.x] is a plain ordinal position (a generation number, a
  /// step index, ...) — ticks format as the rounded integer itself.
  ordinal,
}

/// One `(x, y)` sample. [x] is always already resolved to a plain double —
/// see [ChartPoint.time] / [ChartPoint.ordinal] for the two ways callers
/// build one — so the painter never special-cases the axis kind mid-layout;
/// only tick FORMATTING depends on [ChartXAxisKind].
@immutable
class ChartPoint {
  /// Creates a point directly from an already-resolved [x].
  const ChartPoint(this.x, this.y);

  /// Creates a point on a TIME axis: [x] becomes [t]'s
  /// `millisecondsSinceEpoch`, matching [ChartXAxisKind.time].
  ChartPoint.time(DateTime t, double y)
      : x = t.millisecondsSinceEpoch.toDouble(),
        y = y;

  /// Creates a point on an ORDINAL axis: [x] is [index] itself, matching
  /// [ChartXAxisKind.ordinal] (e.g. a generation number).
  ChartPoint.ordinal(num index, double y)
      : x = index.toDouble(),
        y = y;

  /// Horizontal position — a millisecond timestamp or an ordinal index,
  /// per the owning chart's [ChartXAxisKind].
  final double x;

  /// Sample value.
  final double y;
}

/// One named, colored series ready for [LineChart]/[StateStrip] to render.
@immutable
class ChartSeries {
  /// Creates a series. [color] is resolved by the caller (typically via
  /// [CategoricalPalette] or a status role) — the chart widgets never pick
  /// colors themselves, so "color follows the entity" stays true at every
  /// call site.
  const ChartSeries({
    required this.name,
    required this.color,
    required this.points,
  });

  /// Display name (legend label / tooltip row / table column header).
  final String name;

  /// The series' fixed display color.
  final Color color;

  /// Samples, in ascending [ChartPoint.x] order — every painter in this
  /// library assumes this and does not re-sort.
  final List<ChartPoint> points;

  /// The last sample's value, or `null` when [points] is empty.
  double? get latest => points.isEmpty ? null : points.last.y;
}
