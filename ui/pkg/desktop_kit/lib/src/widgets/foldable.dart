/// Foldable widget — one canonical fold/expand convention for desktop_kit.
///
/// Two public symbols:
/// - [Foldable]: a controlled fold with optional async lazy-load spinner.
/// - [ExpandCollapseAllBar]: a two-button toolbar for bulk expand/collapse.
library;

import 'package:flutter/material.dart';

/// A controlled, tappable fold/expand widget.
///
/// The caller owns the [expanded] state and receives toggle events via
/// [onToggle].  The widget never mutates external state on its own — it
/// is purely controlled.
///
/// If [onExpand] is provided, tapping to *open* the fold awaits the future
/// before calling [onToggle].  During that wait the chevron is replaced by
/// a small [CircularProgressIndicator] (the mountbridge lazy-load pattern).
/// Transient loading state is managed internally so the caller only has to
/// handle the settled [expanded] value.
///
/// Collapsed icon : [collapsedIcon] (default [Icons.chevron_right])
/// Expanded  icon : [expandedIcon] (default [Icons.expand_more])
class Foldable extends StatefulWidget {
  /// Creates a [Foldable].
  const Foldable({
    required this.expanded,
    required this.onToggle,
    required this.header,
    this.child,
    this.tooltip,
    this.onExpand,
    this.expandedIcon = Icons.expand_more,
    this.collapsedIcon = Icons.chevron_right,
    this.iconSize = 20,
    this.iconColor,
    super.key,
  });

  /// Whether the fold is currently open.
  final bool expanded;

  /// Called when the user taps the header row.
  ///
  /// The callback is fired *after* any [onExpand] future completes (when
  /// transitioning from collapsed → expanded).
  final VoidCallback onToggle;

  /// Widget shown in the header row, to the right of the expand icon.
  final Widget header;

  /// Content shown below the header when [expanded] is `true`.
  final Widget? child;

  /// Optional tooltip for the header row.
  final String? tooltip;

  /// Optional async callback called when the user taps to *expand* the fold.
  ///
  /// While the future is pending the chevron is replaced by a
  /// [CircularProgressIndicator].  Once the future completes [onToggle] is
  /// called.  If [expanded] is already `true` this is not called — it fires
  /// only on the collapsed → expanded transition.
  final Future<void> Function()? onExpand;

  /// Icon shown while [expanded] is `true` (default [Icons.expand_more]).
  final IconData expandedIcon;

  /// Icon shown while collapsed (default [Icons.chevron_right]).
  final IconData collapsedIcon;

  /// Size of the leading icon (default 20).
  final double iconSize;

  /// Colour of the leading icon; `null` inherits the ambient [IconTheme].
  final Color? iconColor;

  @override
  State<Foldable> createState() => _FoldableState();
}

class _FoldableState extends State<Foldable> {
  /// `true` while an [Foldable.onExpand] future is in-flight.
  bool _loading = false;

  Future<void> _handleTap() async {
    if (!widget.expanded && widget.onExpand != null) {
      setState(() => _loading = true);
      try {
        await widget.onExpand!();
      } finally {
        if (mounted) {
          setState(() => _loading = false);
        }
      }
    }
    if (mounted) {
      widget.onToggle();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget leadingIcon = _loading
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            widget.expanded ? widget.expandedIcon : widget.collapsedIcon,
            size: widget.iconSize,
            color: widget.iconColor,
          );

    final Widget headerRow = InkWell(
      onTap: _handleTap,
      child: Row(
        children: [
          leadingIcon,
          const SizedBox(width: 4),
          Expanded(child: widget.header),
        ],
      ),
    );

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.tooltip != null
            ? Tooltip(message: widget.tooltip!, child: headerRow)
            : headerRow,
        if (widget.expanded && widget.child != null) widget.child!,
      ],
    );

    return content;
  }
}

/// A small two-button toolbar for bulk expand / collapse operations.
///
/// Renders an "Expand all" button ([Icons.unfold_more]) and a
/// "Collapse all" button ([Icons.unfold_less]).  The caller handles the
/// actual state changes via [onExpandAll] and [onCollapseAll].
class ExpandCollapseAllBar extends StatelessWidget {
  /// Creates an [ExpandCollapseAllBar].
  const ExpandCollapseAllBar({
    required this.onExpandAll,
    required this.onCollapseAll,
    super.key,
  });

  /// Called when the user taps "Expand all".
  final VoidCallback onExpandAll;

  /// Called when the user taps "Collapse all".
  final VoidCallback onCollapseAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: onExpandAll,
          icon: const Icon(Icons.unfold_more),
          label: const Text('Expand all'),
        ),
        TextButton.icon(
          onPressed: onCollapseAll,
          icon: const Icon(Icons.unfold_less),
          label: const Text('Collapse all'),
        ),
      ],
    );
  }
}
