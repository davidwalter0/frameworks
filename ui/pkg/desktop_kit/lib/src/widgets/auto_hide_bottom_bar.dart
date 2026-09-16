/// AutoHideBottomBar — a scrollable body with a bottom bar that auto-hides
/// on downward scroll and can be pulled back up via a drag or tap.
///
/// Public symbols:
/// - [AutoHideBottomBar]: wraps a [body] and a [bar], auto-hiding the bar on
///   `ScrollDirection.reverse` and revealing it on `ScrollDirection.forward`
///   or a drag-up gesture from the bottom edge.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// An auto-hiding, pull-up bottom bar widget.
///
/// Wraps a scrollable [body] and a [bar] (e.g. a [NavigationBar]) so that the
/// bar:
///
/// - **Auto-hides on downward scroll** — a `ScrollDirection.reverse` event
///   (content scrolling down) causes the bar to slide out of view.
/// - **Reveals on upward scroll** — a `ScrollDirection.forward` event
///   (content scrolling up) slides the bar back in.
/// - **Can be pulled up** — a [GestureDetector] at the bottom edge detects an
///   upward drag (`onVerticalDragUpdate`) and reveals the bar. While hidden, a
///   small rounded pill *peek handle* is rendered at the bottom edge as a
///   discoverable affordance; tapping or dragging it up reveals the bar.
/// - **Optional inactivity timer** — if [autoHideAfter] is provided, the bar
///   hides automatically after the given [Duration] of inactivity (the timer
///   resets on every show event). Pass `null` to disable the timeout.
///
/// The [body] receives bottom padding equal to the current visible bar height
/// so its content is never obscured while the bar is shown.
///
/// ```dart
/// AutoHideBottomBar(
///   body: MyScrollableContent(),
///   bar: NavigationBar(
///     selectedIndex: _index,
///     onDestinationSelected: (i) => setState(() => _index = i),
///     destinations: const [...],
///   ),
///   autoHideAfter: const Duration(seconds: 3),
/// )
/// ```
class AutoHideBottomBar extends StatefulWidget {
  /// Creates an [AutoHideBottomBar].
  ///
  /// [body] is the scrollable content area.
  /// [bar] is the widget to show/hide at the bottom (e.g. a [NavigationBar]).
  /// [autoHideAfter] is an optional duration after which the bar auto-hides
  /// when idle; `null` disables the timeout.
  /// [barHeight] is the height reserved for the bar (defaults to
  /// [kBottomNavigationBarHeight]).
  /// [onVisibilityChanged] is called whenever the bar visibility changes.
  const AutoHideBottomBar({
    super.key,
    required this.body,
    required this.bar,
    this.autoHideAfter,
    this.barHeight = kBottomNavigationBarHeight,
    this.onVisibilityChanged,
  });

  /// The scrollable content shown in the main area.
  final Widget body;

  /// The bar widget shown at the bottom (e.g. [NavigationBar]).
  final Widget bar;

  /// How long to wait after the bar is shown before auto-hiding it.
  ///
  /// `null` disables the inactivity timer.
  final Duration? autoHideAfter;

  /// The height of the [bar]; used for padding and slide calculations.
  final double barHeight;

  /// Called whenever the bar transitions between visible and hidden.
  final ValueChanged<bool>? onVisibilityChanged;

  @override
  State<AutoHideBottomBar> createState() => _AutoHideBottomBarState();
}

class _AutoHideBottomBarState extends State<AutoHideBottomBar> {
  bool _barVisible = true;
  Timer? _hideTimer;

  /// Height of the peek handle shown when the bar is hidden.
  static const double _peekHeight = 20.0;

  /// Width of the rounded pill inside the peek handle.
  static const double _pillWidth = 40.0;

  /// Height of the rounded pill inside the peek handle.
  static const double _pillHeight = 4.0;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show() {
    if (!_barVisible) {
      setState(() => _barVisible = true);
      widget.onVisibilityChanged?.call(true);
    }
    _resetTimer();
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_barVisible) {
      setState(() => _barVisible = false);
      widget.onVisibilityChanged?.call(false);
    }
  }

  void _resetTimer() {
    _hideTimer?.cancel();
    if (widget.autoHideAfter != null) {
      _hideTimer = Timer(widget.autoHideAfter!, _hide);
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse) {
        _hide();
      } else if (notification.direction == ScrollDirection.forward) {
        _show();
      }
    }
    // Return false so the notification continues to bubble.
    return false;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // Negative dy means dragging upward (finger moving toward top of screen).
    if (details.delta.dy < 0) {
      _show();
    }
  }

  @override
  Widget build(BuildContext context) {
    // The body padding when the bar is visible equals the bar height; zero
    // when hidden (so the body can use the extra space).
    final double bodyBottomPad = _barVisible ? widget.barHeight : 0.0;

    return Stack(
      children: <Widget>[
        // Body — padded so its content is not obscured by the bar.
        Positioned.fill(
          bottom: bodyBottomPad,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: widget.body,
          ),
        ),

        // Animated bar at the bottom.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSlide(
            offset: _barVisible ? Offset.zero : const Offset(0, 1),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: SizedBox(
              height: widget.barHeight,
              child: widget.bar,
            ),
          ),
        ),

        // Peek handle — only shown when bar is hidden; sits at the very bottom
        // edge so the user can tap or drag up to reveal the bar.
        if (!_barVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              key: const ValueKey<String>('auto_hide_peek_handle'),
              behavior: HitTestBehavior.opaque,
              onTap: _show,
              onVerticalDragUpdate: _onDragUpdate,
              child: SizedBox(
                height: _peekHeight,
                child: Center(
                  child: Container(
                    width: _pillWidth,
                    height: _pillHeight,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.38),
                      borderRadius: BorderRadius.circular(_pillHeight / 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
