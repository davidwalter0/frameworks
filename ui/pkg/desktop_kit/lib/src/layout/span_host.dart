// Pinned, resizable "span" panes — a strip docked at the top or bottom of a
// page body, layout-integrated (a Column, not an overlay/route).
//
// Ported from word-bank's SpanPane/SpanHeightField/SpanDragHandle
// (lib/features/lookup/span_pane.dart) and the `_withSpan` Column composition
// (lib/features/home/home_page.dart), generalized over a [WidgetBuilder] and
// made a reusable controlled widget: the host passes the pinned state +
// height and receives commit callbacks — the kit owns no persistence.
//
// Height semantics (double-clamp, from word-bank):
//  * the host persists a fixed px height (not a ratio — the same value means
//    the same thing across window sizes and survives restart), clamped at the
//    settings layer to [minHeight, maxHeight];
//  * at layout time the effective height is re-clamped against the viewport
//    so the body pane can never be fully displaced
//    (viewportMax = maxHeight(constraints) − handle − [minBodyHeight]).
//  * live drags use an ephemeral height; commits are debounced
//    ([kSpanCommitDebounce]) to the host via [SpanHost.onHeightCommitted]
//    (mirroring SettingsStore's debounced-save idiom).

import 'dart:async';

import 'package:flutter/material.dart';

/// Minimum span-pane height: header + a couple of content lines.
const double kSpanMinHeight = 156.0;

/// Maximum persisted span-pane height (viewport clamp applies below this).
const double kSpanMaxHeight = 2000.0;

/// Minimum height the page BODY keeps when a span is open — the span can
/// never fully displace the content it annotates.
const double kSpanMinBodyHeight = 120.0;

/// Height of the span pane's own header row (title + height field + close).
const double kSpanHeaderHeight = 40.0;

/// Thickness of the drag handle between span and body.
const double kSpanHandleThickness = 8.0;

/// Debounce for committing drag-resizes to the host.
const Duration kSpanCommitDebounce = Duration(milliseconds: 300);

/// Which edge a span pane is pinned to.
enum SpanSide { top, bottom }

/// Hosts a page [child] with an optional pinned, resizable span pane at the
/// top or bottom.
///
/// Controlled widget: the host owns "is a span shown" ([showSpan]), its
/// [side], its persisted [height], and receives [onHeightCommitted] /
/// [onClose] callbacks. Only the EPHEMERAL drag height is internal state.
///
/// ## [child] keeps its Element identity — the host needs no key
///
/// Pinning a span, unpinning it, or moving it between [SpanSide.top] and
/// [SpanSide.bottom] all preserve [child]'s Element, and with it every State
/// object, scroll position, focus and unsaved edit the page holds. That is a
/// guarantee of this widget, not a requirement on the host: **a host does not
/// have to wrap its page in a `GlobalKey` to survive a span toggle.**
///
/// It is a guarantee that has to be BUILT, not assumed, and getting it wrong
/// is invisible. Flutter reconciles a slot by `(runtimeType, key)`, so a build
/// that returned [child] bare while closed and wrapped in a `Column` while
/// open would put two structurally different widgets in one slot; Flutter then
/// disposes the whole child subtree and inflates a fresh one. Nothing looks
/// broken afterwards — the page rebuilt itself from scratch — and only the
/// state it silently dropped is gone. That exact shortcut cost a consuming app
/// every open editor buffer, unsaved edits included, when a settings panel was
/// opened (2026-08-09).
///
/// Two properties hold it, and both are load-bearing:
///
///  * **Constant tree shape.** The `LayoutBuilder > Column > Expanded > child`
///    spine is built in *both* states; the pane and handle are inserted beside
///    the body rather than wrapped around it. The child element is therefore
///    never deactivated at all.
///  * **Keyed slots.** The `Column`'s children are keyed, so flipping [side] —
///    which reverses their order — RE-SLOTS the body (Flutter moves the
///    element) instead of matching by position, which would pair the body
///    against the pane, fail the runtimeType test, and dispose both.
///
/// A `GlobalKey` on [child] is the other way to survive this, and is what the
/// affected app reached for. It is strictly weaker: it repairs the damage
/// rather than preventing it — every State in the subtree still gets
/// `deactivate()`/`activate()`, the render subtree is detached and re-attached
/// — and it only works while the old and new locations are built in the SAME
/// frame. A host may still pass one; it is harmless, and now inert.
///
/// The price of a constant shape is that the slot given to a SpanHost must be
/// bounded in height (the `Expanded`) and in width (the `stretch`) even when
/// no span is pinned. The pinned path always required both.
class SpanHost extends StatefulWidget {
  const SpanHost({
    super.key,
    required this.child,
    required this.showSpan,
    required this.side,
    required this.spanBuilder,
    required this.height,
    required this.onHeightCommitted,
    this.spanTitle = '',
    this.minHeight = kSpanMinHeight,
    this.maxHeight = kSpanMaxHeight,
    this.minBodyHeight = kSpanMinBodyHeight,
    this.onClose,
  });

  /// The page body the span docks against.
  final Widget child;

  /// Whether the span pane is currently shown.
  final bool showSpan;

  /// Which edge the span is pinned to.
  final SpanSide side;

  /// Builds the span pane's content (below its header).
  final WidgetBuilder spanBuilder;

  /// Title shown in the span header row.
  final String spanTitle;

  /// Persisted pane height in logical px (host-owned).
  final double height;

  /// Settings-layer clamp bounds for [height].
  final double minHeight;
  final double maxHeight;

  /// Minimum body height preserved at layout time.
  final double minBodyHeight;

  /// Called (debounced for drags, immediate for the height field) when the
  /// user commits a new height. Host persists it.
  final ValueChanged<double> onHeightCommitted;

  /// Called when the user closes the span (header close button).
  final VoidCallback? onClose;

  @override
  State<SpanHost> createState() => _SpanHostState();
}

class _SpanHostState extends State<SpanHost> {
  /// Stable identities for the [Column]'s slots. Unkeyed children are matched
  /// by POSITION, so reversing the order for [SpanSide.bottom] would pair the
  /// body against the pane; keys turn the same flip into a re-slot. See the
  /// [SpanHost] doc.
  static const Key _paneSlot = ValueKey<String>('span-host-pane');
  static const Key _handleSlot = ValueKey<String>('span-host-handle');
  static const Key _bodySlot = ValueKey<String>('span-host-body');

  /// Ephemeral height during a drag; null when not dragging.
  double? _dragHeight;
  Timer? _commitTimer;

  @override
  void didUpdateWidget(covariant SpanHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // External height change (settings reload) wins unless mid-drag.
    if (widget.height != oldWidget.height && _commitTimer == null) {
      _dragHeight = null;
    }
    if (!widget.showSpan) {
      _dragHeight = null;
      _commitTimer?.cancel();
      _commitTimer = null;
    }
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    super.dispose();
  }

  void _onDragDelta(double dy, double viewportMax) {
    // Dragging DOWN grows a top span but shrinks a bottom span.
    final double current = _dragHeight ?? widget.height;
    final double next =
        widget.side == SpanSide.top ? current + dy : current - dy;
    setState(() {
      _dragHeight = next.clamp(
        widget.minHeight,
        viewportMax < widget.minHeight ? widget.minHeight : viewportMax,
      );
    });
    _commitTimer?.cancel();
    _commitTimer = Timer(kSpanCommitDebounce, () {
      _commitTimer = null;
      final double? h = _dragHeight;
      if (h != null)
        widget.onHeightCommitted(h.clamp(widget.minHeight, widget.maxHeight));
    });
  }

  /// The Column both states share. `stretch` is load-bearing, not taste: the
  /// default (center) hands children LOOSE cross-axis constraints, and the
  /// code this replaces returned the child BARE when closed — i.e. with the
  /// host's own constraints, tight width included. Without `stretch` every
  /// page that never opens a span would quietly start shrink-wrapping and
  /// re-centring. It also makes the two states agree, which is the point: the
  /// body must not observe the span in any axis but the one it takes extent
  /// from.
  Widget _column(List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );

  @override
  Widget build(BuildContext context) {
    // The spine below — LayoutBuilder > Column > Expanded > child — is built
    // whether or not a span is pinned, so the child occupies the same slot
    // under the same ancestors in both states. An `if (!showSpan) return
    // widget.child;` shortcut here reads as an optimization and is a silent
    // data-loss bug: it swaps the element in that slot and Flutter disposes
    // the page. See the SpanHost doc for the incident and the reasoning.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget body = Expanded(key: _bodySlot, child: widget.child);
        if (!widget.showSpan) return _column(<Widget>[body]);

        // Viewport clamp: span + handle + minimum body must fit.
        final double viewportMax = (constraints.maxHeight -
                kSpanHandleThickness -
                widget.minBodyHeight)
            .clamp(widget.minHeight, double.infinity);
        final double requested = _dragHeight ?? widget.height;
        final double effective = requested
            .clamp(widget.minHeight, widget.maxHeight)
            .clamp(widget.minHeight, viewportMax);

        final Widget pane = SpanPane(
          key: _paneSlot,
          title: widget.spanTitle,
          height: effective,
          minHeight: widget.minHeight,
          maxHeight: viewportMax,
          onClose: widget.onClose ?? () {},
          onHeightCommitted: widget.onHeightCommitted,
          builder: widget.spanBuilder,
        );
        final Widget handle = SpanDragHandle(
          key: _handleSlot,
          onDragDelta: (double dy) => _onDragDelta(dy, viewportMax),
        );

        return _column(
          widget.side == SpanSide.top
              ? <Widget>[pane, handle, body]
              : <Widget>[body, handle, pane],
        );
      },
    );
  }
}

/// The pinned, resizable pane itself: a compact header (title + height field
/// + close) above the scrollable content. The header owns the only close
/// affordance, so content is built without its own.
class SpanPane extends StatelessWidget {
  const SpanPane({
    super.key,
    required this.title,
    required this.height,
    required this.minHeight,
    required this.maxHeight,
    required this.onClose,
    required this.onHeightCommitted,
    required this.builder,
  });

  final String title;
  final double height;
  final double minHeight;
  final double maxHeight;
  final VoidCallback onClose;
  final ValueChanged<double> onHeightCommitted;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      elevation: 1,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: kSpanHeaderHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    SpanHeightField(
                      height: height,
                      min: minHeight,
                      max: maxHeight,
                      onCommitted: onHeightCommitted,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      key: const ValueKey('span-close-button'),
                      icon: const Icon(Icons.close),
                      iconSize: 18,
                      tooltip: 'Close',
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(child: builder(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact numeric field for the span pane's height, in logical px.
/// Commits on Enter (`onSubmitted`) or on losing focus (blur), clamping to
/// [min] .. [max]. Re-syncs its displayed text when [height] changes
/// externally (drag, settings reload) while the field isn't focused.
class SpanHeightField extends StatefulWidget {
  const SpanHeightField({
    super.key,
    required this.height,
    required this.min,
    required this.max,
    required this.onCommitted,
  });

  final double height;
  final double min;
  final double max;
  final ValueChanged<double> onCommitted;

  @override
  State<SpanHeightField> createState() => _SpanHeightFieldState();
}

class _SpanHeightFieldState extends State<SpanHeightField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.height.round().toString(),
  );
  late final FocusNode _focusNode = FocusNode()..addListener(_onFocusChange);

  @override
  void didUpdateWidget(covariant SpanHeightField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.height != oldWidget.height) {
      _controller.text = widget.height.round().toString();
    }
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final double? parsed = double.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = widget.height.round().toString();
      return;
    }
    final double clamped = parsed.clamp(widget.min, widget.max);
    _controller.text = clamped.round().toString();
    widget.onCommitted(clamped);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 32,
      child: TextField(
        key: const ValueKey('span-height-field'),
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: const TextInputType.numberWithOptions(),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

/// A thin, draggable strip between the span pane and the page body. Reports
/// the raw pointer delta (positive = downward); whether that grows or shrinks
/// the pane is the caller's call — it differs for a top vs. bottom span.
class SpanDragHandle extends StatefulWidget {
  const SpanDragHandle({super.key, required this.onDragDelta});

  /// Called with the pointer's vertical delta on every drag update.
  final ValueChanged<double> onDragDelta;

  @override
  State<SpanDragHandle> createState() => _SpanDragHandleState();
}

class _SpanDragHandleState extends State<SpanDragHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color dividerColor = _hovered
        ? theme.colorScheme.primary.withValues(alpha: 0.6)
        : theme.dividerColor;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: const ValueKey('span-drag-handle'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (DragUpdateDetails d) =>
            widget.onDragDelta(d.delta.dy),
        child: SizedBox(
          height: kSpanHandleThickness,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(height: 1, color: dividerColor),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Icon(
                  Icons.drag_handle,
                  size: 16,
                  color: _hovered
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
