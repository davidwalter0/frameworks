/// Hand-rolled charting primitives for the `desktop_kit` package — zero
/// external charting-package dependency, one `CustomPainter` per widget.
/// Generalized from gatehub-kit/ui/ghk_dashboard's chart engine; see
/// `src/charts/chart_series.dart`'s library doc for the full provenance
/// note.
///
/// Exports:
/// - [ChartPoint] / [ChartSeries] / [ChartXAxisKind] — the shared, source-
///   agnostic data model (time OR ordinal x-axis).
/// - [CategoricalPalette] / [kCategoricalLight] / [kCategoricalDark] /
///   [categoricalPaletteFor] — "color follows the entity" categorical
///   series-color assignment, snap-to-passing derived from [DeskPalette].
/// - [LineChart]           — multi-series line chart: hover crosshair +
///                            tooltip, toggleable legend, table-view
///                            fallback.
/// - [SmallMultiples] / [SmallMultipleFacet] — a responsive small-multiples
///                            grid for faceting a dataset instead of dual-
///                            axing or overplotting one chart.
/// - [StateStrip] / [HealthState] — a per-row categorical health/state
///                            timeline, status-colored (never categorical
///                            hue).
/// - [niceCeil] / [formatAxisTick] / [formatOrdinalTick] /
///   [formatTooltipTime] — pure axis/tooltip formatting helpers.
library;

export 'src/charts/categorical_palette.dart';
export 'src/charts/chart_format.dart';
export 'src/charts/chart_series.dart';
export 'src/charts/line_chart.dart';
export 'src/charts/small_multiples.dart';
export 'src/charts/state_strip.dart';
