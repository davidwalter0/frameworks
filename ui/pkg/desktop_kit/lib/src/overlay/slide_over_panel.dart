// A slide-over panel that opens from a screen edge (right / bottom / top) —
// the desktop "compare drawer" / "detail flyout" pattern.
//
// ── Why a route, never a hand-inserted OverlayEntry (READ THIS) ───────────
// [showSlideOverPanel] pushes a real [PageRouteBuilder] through the
// [Navigator]. It deliberately does NOT call `Overlay.of(context).insert
// (OverlayEntry(...))` directly. An `OverlayEntry` inserted by hand sits at
// a fixed position in the ambient [Overlay]'s entry list and OUTRANKS any
// route pushed after it — so a dialog opened from a widget living inside
// that OverlayEntry (via `showDialog`, which itself pushes a route) renders
// UNDERNEATH the OverlayEntry, not above it. A route pushed through the
// Navigator has no such trap: the Navigator's Overlay stacks routes in push
// order, so anything pushed from inside this panel (a dialog, another
// route) always paints above it, regardless of this panel's own
// `opaque: false`. [SlideOverPanel]'s own regression test
// ("a dialog pushed from inside the panel renders above it") is the
// concrete proof this trap cannot recur here.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Which screen edge a [SlideOverPanel] slides in from.
enum SlideEdge {
  /// Slides in from the right edge, sized by width, full height.
  right,

  /// Slides in from the bottom edge, sized by height, full width.
  bottom,

  /// Slides in from the top edge, sized by height, full width.
  top,
}

/// Pushes [builder]'s content as a [SlideOverPanel] via a proper modal
/// [PageRouteBuilder] (see the library doc for why a route, not an
/// [OverlayEntry]). Returns the value the panel is popped with, exactly
/// like [showDialog]/[Navigator.push].
///
/// - [edge] picks which screen edge the panel slides in from.
/// - [title] is shown in the panel's header, next to the always-present
///   close button; `null` renders just the close button.
/// - [semanticLabel] announces the panel to assistive technology (falls
///   back to [title], then a generic label) and doubles as the modal
///   barrier's `barrierLabel`.
/// - [barrierColor] is the scrim painted behind the panel; tapping it (or
///   pressing Escape, or the header's close button) dismisses the panel —
///   all three call [Navigator.maybePop] with no value.
/// - Reduced motion: when `MediaQuery.disableAnimationsOf(context)` is
///   true, the slide/fade transition is skipped ([Duration.zero]) rather
///   than merely shortened, matching the house "respect reduced-motion by
///   shortening/skipping the animation" rule.
Future<T?> showSlideOverPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  SlideEdge edge = SlideEdge.right,
  String? title,
  String? semanticLabel,
  Color? barrierColor,
  Duration transitionDuration = const Duration(milliseconds: 250),
}) {
  final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
  final Duration duration = reduceMotion ? Duration.zero : transitionDuration;
  final String label = semanticLabel ?? title ?? 'Panel';

  return Navigator.of(context).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: barrierColor ?? Colors.black54,
      barrierLabel: label,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (
        BuildContext routeContext,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) {
        return SlideOverPanel(
          edge: edge,
          title: title,
          semanticLabel: semanticLabel,
          child: Builder(builder: builder),
        );
      },
      transitionsBuilder: (
        BuildContext routeContext,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
        Widget child,
      ) {
        final Offset begin = switch (edge) {
          SlideEdge.right => const Offset(1, 0),
          SlideEdge.bottom => const Offset(0, 1),
          SlideEdge.top => const Offset(0, -1),
        };
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        );
      },
    ),
  );
}

/// The panel widget itself: an edge-anchored, size-clamped, scrollable card
/// with a header (optional [title] + an always-present close button),
/// Escape-to-close, and a container [Semantics] label. Normally reached via
/// [showSlideOverPanel] rather than constructed directly, but it takes no
/// route-specific state, so a caller wanting a non-modal embed (e.g. inside
/// its own already-modal surface) may use it standalone.
class SlideOverPanel extends StatelessWidget {
  /// Creates a slide-over panel.
  const SlideOverPanel({
    super.key,
    required this.edge,
    required this.child,
    this.title,
    this.semanticLabel,
    this.maxWidth = 560,
    this.maxWidthFraction = 0.9,
    this.maxHeight = 600,
    this.maxHeightFraction = 0.7,
  });

  /// Which edge this panel is anchored to.
  final SlideEdge edge;

  /// The panel's content — placed inside a [SingleChildScrollView], so it
  /// is free to be taller than the panel's clamped extent without
  /// overflowing.
  final Widget child;

  /// Optional header title.
  final String? title;

  /// Optional accessibility label for the panel container; defaults to
  /// [title], then a generic label.
  final String? semanticLabel;

  /// Absolute cap on panel width ([SlideEdge.right]), logical px.
  final double maxWidth;

  /// Fraction-of-window cap on panel width ([SlideEdge.right]) — the
  /// SMALLER of this and [maxWidth] wins, so the panel never crowds out a
  /// narrow window even before [maxWidth] would otherwise allow it to.
  final double maxWidthFraction;

  /// Absolute cap on panel height ([SlideEdge.bottom] / [SlideEdge.top]),
  /// logical px.
  final double maxHeight;

  /// Fraction-of-window cap on panel height ([SlideEdge.bottom] /
  /// [SlideEdge.top]) — the SMALLER of this and [maxHeight] wins.
  final double maxHeightFraction;

  @override
  Widget build(BuildContext context) {
    final Size windowSize = MediaQuery.sizeOf(context);
    final bool horizontal = edge == SlideEdge.right;

    // Never a hard-coded constant (house layout rule) -- always the min of
    // the absolute cap and a fraction of the CURRENT window, so a small
    // window cannot reproduce an overflow a large one never showed.
    final double panelWidth = horizontal
        ? math.min(maxWidth, windowSize.width * maxWidthFraction)
        : windowSize.width;
    final double panelHeight = horizontal
        ? windowSize.height
        : math.min(maxHeight, windowSize.height * maxHeightFraction);

    final Alignment alignment = switch (edge) {
      SlideEdge.right => Alignment.centerRight,
      SlideEdge.bottom => Alignment.bottomCenter,
      SlideEdge.top => Alignment.topCenter,
    };

    final Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: <Widget>[
          if (title != null)
            Expanded(
              child: Text(
                title!,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          IconButton(
            key: const ValueKey<String>('slide-over-panel-close'),
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );

    // Bounded extent (panelHeight, above) means content taller than that
    // MUST scroll rather than overflow -- the house dialog/sheet rule.
    final Widget body = Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: SingleChildScrollView(
          key: const ValueKey<String>('slide-over-panel-body'),
          child: child,
        ),
      ),
    );

    return Align(
      alignment: alignment,
      child: Semantics(
        container: true,
        label: semanticLabel ?? title ?? 'Panel',
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).maybePop(),
          },
          child: Focus(
            autofocus: true,
            // Focus solely to make the CallbackShortcuts above receive key
            // events reliably in every host (see class doc) -- this node
            // does not itself need to be reachable by Tab traversal ahead
            // of the panel's real controls.
            skipTraversal: true,
            child: Material(
              key: const ValueKey<String>('slide-over-panel'),
              elevation: 16,
              color: Theme.of(context).colorScheme.surface,
              child: SizedBox(
                width: panelWidth,
                height: panelHeight,
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      header,
                      const Divider(height: 1),
                      body,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
