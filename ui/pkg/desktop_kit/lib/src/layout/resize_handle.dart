// A draggable resize handle between two panes. Pure widget (moved verbatim
// from task-board's app-local ResizeHandle): reports raw pointer deltas via
// [onResize]; the caller interprets them (fraction math, clamping).

import 'package:flutter/material.dart';

/// A draggable resize handle between two panels.
class ResizeHandle extends StatelessWidget {
  const ResizeHandle({
    super.key,
    required this.axis,
    required this.onResize,
    this.thickness = 6,
  });

  /// Which way the divider runs: [Axis.horizontal] = vertical divider between
  /// side-by-side panes (drag left/right); [Axis.vertical] = horizontal
  /// divider between stacked panes (drag up/down).
  final Axis axis;

  /// Called with the raw pointer delta on every drag update
  /// (`delta.dx` for horizontal, `delta.dy` for vertical).
  final void Function(double delta) onResize;

  /// Divider thickness in logical px.
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isHorizontal = axis == Axis.horizontal;

    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: isHorizontal
            ? (DragUpdateDetails details) => onResize(details.delta.dx)
            : null,
        onVerticalDragUpdate: !isHorizontal
            ? (DragUpdateDetails details) => onResize(details.delta.dy)
            : null,
        child: Container(
          width: isHorizontal ? thickness : double.infinity,
          height: isHorizontal ? double.infinity : thickness,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          child: Center(
            child: Container(
              width: isHorizontal ? 2 : 32,
              height: isHorizontal ? 32 : 2,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
