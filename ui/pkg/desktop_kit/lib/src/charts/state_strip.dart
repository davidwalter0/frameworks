// A per-row categorical health/state timeline: one horizontal strip per
// row, each segment colored by RESERVED STATUS roles (ok/warn/danger) —
// never categorical hue — since the strip encodes STATE, not entity
// identity. Per the dataviz skill's status rule, every status color ships
// paired with an icon + label (the row's leading icon+name, plus the
// always-on legend).
//
// Provenance: promoted from gatehub-kit/ui/ghk_dashboard's
// `lib/src/charts/state_strip.dart` (see chart_series.dart's library doc);
// unchanged apart from following [ChartPoint]'s generalized `x`/`y` fields
// (it was already `time`/`value`-agnostic in spirit — segments are ordered
// by [ChartPoint.x], classified by [ChartPoint.y] — only the field names
// moved).
library;

import 'package:flutter/material.dart';

import 'chart_format.dart';
import 'chart_series.dart';

/// The three health states a [StateStrip] segment can render.
enum HealthState {
  /// Value `>= 1` — the row is healthy.
  healthy(Icons.check_circle, 'Healthy'),

  /// Value in `(0, 1)` — partially healthy / degraded.
  degraded(Icons.warning_amber, 'Degraded'),

  /// Value `<= 0` — the row is down.
  down(Icons.error, 'Down');

  const HealthState(this.icon, this.label);

  /// Status icon paired with every use of this state's color.
  final IconData icon;

  /// Status label paired with every use of this state's color.
  final String label;

  /// Classifies a raw sample value (e.g. an `up`-style gauge).
  static HealthState of(double v) {
    if (v >= 1) return HealthState.healthy;
    if (v <= 0) return HealthState.down;
    return HealthState.degraded;
  }
}

/// A per-row health/state timeline. [rows] carries one [ChartSeries] per row
/// (its `name` is the row label; its points' `y` values are classified
/// per-segment via [HealthState.of], ordered by `x`). Colors are supplied by
/// the caller (status-role colors from [DeskPalette]) via
/// [okColor]/[warnColor]/[dangerColor] so this widget never guesses semantic
/// colors on its own.
class StateStrip extends StatefulWidget {
  /// Creates a state strip.
  const StateStrip({
    super.key,
    required this.rows,
    required this.emptyMessage,
    required this.okColor,
    required this.warnColor,
    required this.dangerColor,
    this.title,
    this.rowHeight = 22,
  });

  /// One series per row.
  final List<ChartSeries> rows;

  /// Shown instead of the strip when [rows] is empty.
  final String emptyMessage;

  /// Status color for [HealthState.healthy].
  final Color okColor;

  /// Status color for [HealthState.degraded].
  final Color warnColor;

  /// Status color for [HealthState.down].
  final Color dangerColor;

  /// Optional title, shown above the strip.
  final String? title;

  /// Height of each row's strip.
  final double rowHeight;

  @override
  State<StateStrip> createState() => _StateStripState();
}

class _StateStripState extends State<StateStrip> {
  bool _showTable = false;

  Color _colorOf(HealthState s) => switch (s) {
        HealthState.healthy => widget.okColor,
        HealthState.degraded => widget.warnColor,
        HealthState.down => widget.dangerColor,
      };

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool noData = widget.rows.isEmpty;

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
                  tooltip: _showTable ? 'Show timeline' : 'Show table',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _showTable
                        ? Icons.view_timeline_outlined
                        : Icons.table_chart_outlined,
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
              _statusLegend(context, cs),
              const SizedBox(height: 8),
              _showTable ? _buildTable(context) : _buildTimeline(context, cs),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusLegend(BuildContext context, ColorScheme cs) {
    Widget chip(HealthState s) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(s.icon, size: 14, color: _colorOf(s)),
            const SizedBox(width: 4),
            Text(
              s.label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        );
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: <Widget>[
        for (final HealthState s in HealthState.values) chip(s)
      ],
    );
  }

  Widget _buildTimeline(BuildContext context, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ChartSeries s in widget.rows) _row(context, cs, s),
      ],
    );
  }

  Widget _row(BuildContext context, ColorScheme cs, ChartSeries s) {
    final HealthState latest = s.points.isEmpty
        ? HealthState.degraded
        : HealthState.of(s.points.last.y);
    final String message = s.points.isEmpty
        ? '${s.name}: no samples yet'
        : '${s.name}: ${latest.label.toLowerCase()} '
            '(as of ${_asOf(s.points.last.x)})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: message,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 140,
              child: Row(
                children: <Widget>[
                  Icon(latest.icon, size: 14, color: _colorOf(latest)),
                  const SizedBox(width: 4),
                  Expanded(
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
            Expanded(
              child: SizedBox(
                height: widget.rowHeight,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _StripPainter(
                    points: s.points,
                    okColor: widget.okColor,
                    warnColor: widget.warnColor,
                    dangerColor: widget.dangerColor,
                    surfaceColor: Theme.of(context).cardColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// x is stored as a millisecond timestamp for the common (VictoriaLogs/
  /// Prometheus-derived) health-timeline case this widget was built for;
  /// [formatTooltipTime] is kept as the single "as of" formatter so a
  /// consumer plotting a genuinely ordinal x (unusual for a health strip)
  /// gets an honest, if less pretty, epoch-derived date rather than a second
  /// formatting branch this widget cannot otherwise justify.
  String _asOf(double x) =>
      formatTooltipTime(DateTime.fromMillisecondsSinceEpoch(x.round()));

  Widget _buildTable(BuildContext context) {
    return DataTable(
      columnSpacing: 20,
      headingRowHeight: 32,
      dataRowMinHeight: 28,
      dataRowMaxHeight: 28,
      columns: const <DataColumn>[
        DataColumn(label: Text('Row')),
        DataColumn(label: Text('State')),
        DataColumn(label: Text('As of')),
      ],
      rows: <DataRow>[
        for (final ChartSeries s in widget.rows)
          DataRow(
            cells: <DataCell>[
              DataCell(Text(s.name)),
              DataCell(Text(
                s.points.isEmpty ? '—' : HealthState.of(s.points.last.y).label,
              )),
              DataCell(Text(
                s.points.isEmpty ? '—' : _asOf(s.points.last.x),
              )),
            ],
          ),
      ],
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.points,
    required this.okColor,
    required this.warnColor,
    required this.dangerColor,
    required this.surfaceColor,
  });

  final List<ChartPoint> points;
  final Color okColor;
  final Color warnColor;
  final Color dangerColor;
  final Color surfaceColor;

  Color _colorOf(HealthState s) => switch (s) {
        HealthState.healthy => okColor,
        HealthState.degraded => warnColor,
        HealthState.down => dangerColor,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final RRect track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(3),
    );
    canvas.drawRRect(track, Paint()..color = surfaceColor);
    if (points.isEmpty) return;

    final double xMin = points.first.x;
    final double xMax = points.last.x;
    final double total = xMax - xMin;
    double xFor(double x) => total <= 0 ? 0 : (x - xMin) / total * size.width;

    for (int i = 0; i < points.length; i++) {
      final double left = xFor(points[i].x);
      final double right =
          i + 1 < points.length ? xFor(points[i + 1].x) : size.width;
      final HealthState s = HealthState.of(points[i].y);
      canvas.drawRect(
        Rect.fromLTRB(
            left, 1, (right - 1).clamp(left, size.width), size.height - 1),
        Paint()..color = _colorOf(s),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StripPainter oldDelegate) => true;
}
