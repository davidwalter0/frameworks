// A hand-rolled line chart (CustomPainter) per the dataviz skill's mark
// contract: 2px lines, zero-baseline, recessive hairline grid, an >=8px
// end-marker with a direct value label, crosshair+shared tooltip on hover,
// a click-to-toggle legend for >=2 series, and a table-view fallback so the
// same data is reachable without hovering at all.
//
// Provenance: generalized from gatehub-kit/ui/ghk_dashboard's
// `lib/src/charts/line_chart.dart` (see chart_series.dart's library doc).
// The one substantive generalization: the original assumed a TIME x-axis
// throughout (`DateTime` fields, `formatAxisTick(t, span)`); this version
// takes plain `double x` per [ChartPoint] and a [ChartXAxisKind] so the same
// widget also plots an ORDINAL axis (e.g. a generation number) — see
// [xAxisKind]. Everything else (hover, legend, table, end-marker, mark
// specs) is unchanged.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'chart_format.dart';
import 'chart_series.dart';

/// A titled line chart card: [series] plotted against [xAxisKind], zero-
/// baselined on y, with a hover crosshair+tooltip, a toggleable legend (>=2
/// series), and a "table" view of the same data. Renders [emptyMessage]
/// instead of a chart when every series has no points (the "named series
/// missing" empty state the dataviz contract requires).
class LineChart extends StatefulWidget {
  /// Creates a line chart. [valueFormatter] formats a raw sample value for
  /// axis ticks, direct labels, the tooltip, and the table view — pass a
  /// unit-aware formatter (e.g. `'${v.toStringAsFixed(1)}/s'`).
  const LineChart({
    super.key,
    required this.series,
    required this.emptyMessage,
    this.title,
    this.xAxisKind = ChartXAxisKind.time,
    this.xLabelFormatter,
    this.valueFormatter = _defaultFormatter,
    this.height = 200,
  });

  /// The series to plot; an empty list (or one where every series has no
  /// points) shows [emptyMessage] instead.
  final List<ChartSeries> series;

  /// Shown instead of the chart when there is no data — name the missing
  /// series so the reader knows what's absent (e.g. "no data for
  /// mgk_tool_calls_total yet — is the exporter scraped?").
  final String emptyMessage;

  /// Optional chart title, shown above the plot.
  final String? title;

  /// What [ChartPoint.x] means across every series here — every series on
  /// one chart must share an axis kind, matching the "one axis" dataviz
  /// rule. Drives the default x tick formatting when [xLabelFormatter] is
  /// not supplied.
  final ChartXAxisKind xAxisKind;

  /// Overrides the [xAxisKind]-derived default x tick formatter. Most
  /// callers should leave this null; it exists for a caller that wants e.g.
  /// `'gen 12'` instead of the ordinal default's bare `'12'`.
  final String Function(double x)? xLabelFormatter;

  /// Formats a raw value for axis ticks / direct labels / tooltip / table.
  final String Function(double) valueFormatter;

  /// Plot area height (excludes title/legend/table-toggle chrome).
  final double height;

  static String _defaultFormatter(double v) => v.toStringAsFixed(2);

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  final Set<String> _hidden = <String>{};
  bool _showTable = false;
  Offset? _hover;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool noData = widget.series.isEmpty ||
        widget.series.every((ChartSeries s) => s.points.isEmpty);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (widget.title != null)
                  Expanded(
                    child: Text(
                      widget.title!,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  )
                else
                  const Spacer(),
                IconButton(
                  tooltip: _showTable ? 'Show chart' : 'Show table',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _showTable ? Icons.show_chart : Icons.table_chart_outlined,
                    size: 18,
                  ),
                  onPressed: noData
                      ? null
                      : () => setState(() => _showTable = !_showTable),
                ),
              ],
            ),
            if (noData)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    widget.emptyMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              )
            else ...<Widget>[
              _showTable ? _buildTable(context) : _buildChart(context),
              if (widget.series.length >= 2) _legend(context, cs),
            ],
          ],
        ),
      ),
    );
  }

  List<ChartSeries> get _visible => widget.series
      .where((ChartSeries s) => !_hidden.contains(s.name))
      .toList();

  String _xLabel(double x, Duration span) {
    final String Function(double x)? override = widget.xLabelFormatter;
    if (override != null) return override(x);
    switch (widget.xAxisKind) {
      case ChartXAxisKind.time:
        return formatAxisTick(
            DateTime.fromMillisecondsSinceEpoch(x.round()), span);
      case ChartXAxisKind.ordinal:
        return formatOrdinalTick(x);
    }
  }

  String _xTooltipLabel(double x) {
    switch (widget.xAxisKind) {
      case ChartXAxisKind.time:
        return formatTooltipTime(
            DateTime.fromMillisecondsSinceEpoch(x.round()));
      case ChartXAxisKind.ordinal:
        return widget.xLabelFormatter?.call(x) ?? 'gen ${formatOrdinalTick(x)}';
    }
  }

  Widget _buildChart(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: MouseRegion(
        onHover: (PointerHoverEvent e) =>
            setState(() => _hover = e.localPosition),
        onExit: (PointerExitEvent e) => setState(() => _hover = null),
        child: CustomPaint(
          size: Size.infinite,
          painter: _LineChartPainter(
            series: _visible,
            hover: _hover,
            gridColor: cs.outlineVariant,
            axisTextColor: cs.onSurfaceVariant,
            surfaceColor: Theme.of(context).cardColor,
            valueFormatter: widget.valueFormatter,
            xLabel: _xLabel,
            xTooltipLabel: _xTooltipLabel,
          ),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: <Widget>[
          for (final ChartSeries s in widget.series)
            InkWell(
              onTap: () => setState(() {
                if (_hidden.contains(s.name)) {
                  _hidden.remove(s.name);
                } else {
                  _hidden.add(s.name);
                }
              }),
              child: Opacity(
                opacity: _hidden.contains(s.name) ? 0.4 : 1.0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(width: 14, height: 2, color: s.color),
                    const SizedBox(width: 4),
                    // Flexible + ellipsis, not a bare Text: a series NAME is
                    // caller-supplied and can be long (e.g. an
                    // experiment-prefixed cohort label). Wrap gives this
                    // Row's incoming constraint a bounded maxWidth (the
                    // wrap's own cross-extent), so an unbounded Text here
                    // overflows -- measured 2026-08-12, a 32-char legend
                    // name inside a ~500px-wide compare panel.
                    Flexible(
                      child: Text(
                        s.name,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTable(BuildContext context) {
    final List<ChartSeries> cols = widget.series;
    final ChartSeries longest = cols.reduce(
      (ChartSeries a, ChartSeries b) =>
          a.points.length >= b.points.length ? a : b,
    );
    final List<double> xs = <double>[
      for (final ChartPoint p in longest.points) p.x,
    ];
    String cell(ChartSeries s, double x) {
      final double? v = _nearestValue(s, x);
      return v == null ? '—' : widget.valueFormatter(v);
    }

    return SizedBox(
      height: widget.height,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 20,
          headingRowHeight: 32,
          dataRowMinHeight: 28,
          dataRowMaxHeight: 28,
          columns: <DataColumn>[
            DataColumn(
                label: Text(
                    widget.xAxisKind == ChartXAxisKind.time ? 'Time' : 'X')),
            for (final ChartSeries s in cols) DataColumn(label: Text(s.name)),
          ],
          rows: <DataRow>[
            for (final double x in xs)
              DataRow(
                cells: <DataCell>[
                  DataCell(Text(_xTooltipLabel(x))),
                  for (final ChartSeries s in cols) DataCell(Text(cell(s, x))),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static double? _nearestValue(ChartSeries s, double x) {
    if (s.points.isEmpty) return null;
    ChartPoint nearest = s.points.first;
    double best = (nearest.x - x).abs();
    for (final ChartPoint p in s.points) {
      final double d = (p.x - x).abs();
      if (d < best) {
        best = d;
        nearest = p;
      }
    }
    return nearest.y;
  }
}

/// Fixed chart-area margins, in logical px.
const double _kLeftPad = 52;
const double _kRightPad = 8;
const double _kTopPad = 10;
const double _kBottomPad = 20;

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.series,
    required this.hover,
    required this.gridColor,
    required this.axisTextColor,
    required this.surfaceColor,
    required this.valueFormatter,
    required this.xLabel,
    required this.xTooltipLabel,
  });

  final List<ChartSeries> series;
  final Offset? hover;
  final Color gridColor;
  final Color axisTextColor;
  final Color surfaceColor;
  final String Function(double) valueFormatter;

  /// Formats an x-axis tick, given the chart's total x span (time mode uses
  /// it to pick HH:mm vs MM/DD; ordinal mode ignores it).
  final String Function(double x, Duration span) xLabel;

  /// Formats the crosshair tooltip's header (full-detail x label).
  final String Function(double x) xTooltipLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final List<ChartPoint> allPoints = <ChartPoint>[
      for (final ChartSeries s in series) ...s.points,
    ];
    if (allPoints.isEmpty) return;

    final Rect rect = Rect.fromLTWH(
      _kLeftPad,
      _kTopPad,
      (size.width - _kLeftPad - _kRightPad).clamp(1, double.infinity),
      (size.height - _kTopPad - _kBottomPad).clamp(1, double.infinity),
    );

    double xMin = allPoints.first.x;
    double xMax = allPoints.first.x;
    double rawMax = 0;
    for (final ChartPoint p in allPoints) {
      if (p.x < xMin) xMin = p.x;
      if (p.x > xMax) xMax = p.x;
      if (p.y > rawMax) rawMax = p.y;
    }
    final double vMax = niceCeil(rawMax <= 0 ? 1 : rawMax * 1.05);
    const double vMin = 0; // zero-baseline rule
    final Duration span =
        Duration(milliseconds: (xMax - xMin).round().clamp(0, 1 << 40));

    double xFor(double x) {
      final double total = xMax - xMin;
      if (total <= 0) return rect.left;
      return rect.left + ((x - xMin) / total) * rect.width;
    }

    double yFor(double v) {
      final double spanV = vMax - vMin;
      if (spanV <= 0) return rect.bottom;
      return rect.bottom - ((v - vMin) / spanV) * rect.height;
    }

    _paintGrid(canvas, rect, vMin, vMax, yFor);
    _paintXAxis(canvas, rect, xMin, xMax, span, xFor);

    for (final ChartSeries s in series) {
      _paintSeries(canvas, s, xFor, yFor);
    }

    if (hover != null &&
        rect.contains(
            Offset(hover!.dx.clamp(rect.left, rect.right), rect.top + 1))) {
      _paintCrosshair(canvas, rect, xMin, xMax, xFor, yFor);
    }
  }

  void _paintGrid(
    Canvas canvas,
    Rect rect,
    double vMin,
    double vMax,
    double Function(double) yFor,
  ) {
    final Paint gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const int ticks = 4;
    for (int i = 0; i <= ticks; i++) {
      final double v = vMin + (vMax - vMin) * i / ticks;
      final double y = yFor(v);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), gridPaint);
      _text(
        canvas,
        valueFormatter(v),
        TextStyle(color: axisTextColor, fontSize: 10),
        Offset(rect.left - 6, y),
        align: TextAlign.right,
        anchorRight: true,
        centerVertically: true,
      );
    }
  }

  void _paintXAxis(
    Canvas canvas,
    Rect rect,
    double xMin,
    double xMax,
    Duration span,
    double Function(double) xFor,
  ) {
    const int ticks = 4;
    for (int i = 0; i <= ticks; i++) {
      final double x = xMin + (xMax - xMin) * i / ticks;
      final double px = xFor(x);
      _text(
        canvas,
        xLabel(x, span),
        TextStyle(color: axisTextColor, fontSize: 10),
        Offset(px, rect.bottom + 4),
        centerHorizontally: true,
      );
    }
  }

  void _paintSeries(
    Canvas canvas,
    ChartSeries s,
    double Function(double) xFor,
    double Function(double) yFor,
  ) {
    if (s.points.isEmpty) return;
    final Path path = Path();
    for (int i = 0; i < s.points.length; i++) {
      final Offset p = Offset(xFor(s.points[i].x), yFor(s.points[i].y));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = s.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // End marker (>=8px diameter) with a 2px surface ring, plus the direct
    // value label at the line's end — text in an axis token, never the
    // series color.
    final ChartPoint last = s.points.last;
    final Offset end = Offset(xFor(last.x), yFor(last.y));
    canvas.drawCircle(end, 6, Paint()..color = surfaceColor);
    canvas.drawCircle(end, 4, Paint()..color = s.color);
    _text(
      canvas,
      valueFormatter(last.y),
      TextStyle(
          color: axisTextColor, fontSize: 10, fontWeight: FontWeight.w600),
      Offset(end.dx - 8, end.dy),
      align: TextAlign.right,
      anchorRight: true,
      centerVertically: true,
      background: surfaceColor,
    );
  }

  void _paintCrosshair(
    Canvas canvas,
    Rect rect,
    double xMin,
    double xMax,
    double Function(double) xFor,
    double Function(double) yFor,
  ) {
    final double cx = hover!.dx.clamp(rect.left, rect.right);
    final double total = xMax - xMin;
    final double crossX =
        total <= 0 ? xMin : xMin + total * (cx - rect.left) / rect.width;

    canvas.drawLine(
      Offset(cx, rect.top),
      Offset(cx, rect.bottom),
      Paint()
        ..color = axisTextColor.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    final List<(ChartSeries, ChartPoint)> rows = <(ChartSeries, ChartPoint)>[];
    for (final ChartSeries s in series) {
      if (s.points.isEmpty) continue;
      ChartPoint nearest = s.points.first;
      double best = (nearest.x - crossX).abs();
      for (final ChartPoint p in s.points) {
        final double d = (p.x - crossX).abs();
        if (d < best) {
          best = d;
          nearest = p;
        }
      }
      rows.add((s, nearest));
      final Offset m = Offset(xFor(nearest.x), yFor(nearest.y));
      canvas.drawCircle(m, 5, Paint()..color = surfaceColor);
      canvas.drawCircle(m, 3, Paint()..color = s.color);
    }
    if (rows.isEmpty) return;

    _paintTooltip(canvas, rect, cx, hover!.dy, crossX, rows);
  }

  void _paintTooltip(
    Canvas canvas,
    Rect rect,
    double cx,
    double cy,
    double crossX,
    List<(ChartSeries, ChartPoint)> rows,
  ) {
    const double pad = 8;
    const double rowH = 16;
    final TextStyle headerStyle = TextStyle(
        color: axisTextColor, fontSize: 10, fontWeight: FontWeight.w600);
    final TextPainter header = TextPainter(
      text: TextSpan(text: xTooltipLabel(crossX), style: headerStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    double maxRowWidth = header.width;
    final List<TextPainter> rowPainters = <TextPainter>[];
    for (final (ChartSeries s, ChartPoint p) in rows) {
      final TextPainter tp = TextPainter(
        text: TextSpan(children: <InlineSpan>[
          TextSpan(
            text: valueFormatter(p.y),
            style: TextStyle(
              color: axisTextColor,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(
            text: ' ${s.name}',
            style: TextStyle(
                color: axisTextColor.withValues(alpha: 0.8), fontSize: 10),
          ),
        ]),
        textDirection: TextDirection.ltr,
      )..layout();
      rowPainters.add(tp);
      if (tp.width + 16 > maxRowWidth) maxRowWidth = tp.width + 16;
    }

    final double boxW = maxRowWidth + pad * 2;
    final double boxH = header.height + pad * 2 + rowPainters.length * rowH;

    double left = cx + 12;
    if (left + boxW > rect.right) left = cx - 12 - boxW;
    double top = cy - boxH / 2;
    if (top < rect.top) top = rect.top;
    if (top + boxH > rect.bottom) top = rect.bottom - boxH;

    final Rect box = Rect.fromLTWH(left, top, boxW, boxH);
    final RRect rrect = RRect.fromRectAndRadius(box, const Radius.circular(6));
    canvas.drawRRect(rrect, Paint()..color = surfaceColor);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = gridColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    header.paint(canvas, Offset(box.left + pad, box.top + pad));
    double rowY = box.top + pad + header.height + 2;
    for (int i = 0; i < rows.length; i++) {
      final (ChartSeries s, ChartPoint _) = rows[i];
      // Line key — a short stroke of the series color, not a filled box.
      canvas.drawLine(
        Offset(box.left + pad, rowY + rowH / 2),
        Offset(box.left + pad + 10, rowY + rowH / 2),
        Paint()
          ..color = s.color
          ..strokeWidth = 2,
      );
      rowPainters[i].paint(canvas, Offset(box.left + pad + 16, rowY));
      rowY += rowH;
    }
  }

  void _text(
    Canvas canvas,
    String text,
    TextStyle style,
    Offset at, {
    TextAlign align = TextAlign.left,
    bool anchorRight = false,
    bool centerHorizontally = false,
    bool centerVertically = false,
    Color? background,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    double dx = at.dx;
    if (anchorRight) dx -= tp.width;
    if (centerHorizontally) dx -= tp.width / 2;
    double dy = at.dy;
    if (centerVertically) dy -= tp.height / 2;
    if (background != null) {
      canvas.drawRect(
        Rect.fromLTWH(dx - 2, dy, tp.width + 4, tp.height),
        Paint()..color = background,
      );
    }
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) => true;
}
