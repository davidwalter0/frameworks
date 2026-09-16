// A small circular status "LED" with optional pulse — the notification-status
// dot from the Angular prototype's NotificationLedIndicatorComponent,
// promoted from task-board's app-local LedIndicator and enhanced to carry the
// full design: named sizes, per-status semantics/ARIA labels, high-contrast
// borders, and reduced-motion respect.
//
// The DERIVATION rule (which LedStatus a domain object maps to) is
// deliberately NOT here — that's app domain logic; the kit renders whatever
// status it is handed.

import 'package:flutter/material.dart';

/// Named LED sizes (logical px) matching the Angular component's
/// small/medium/large.
const double kLedSmall = 8;
const double kLedMedium = 12;
const double kLedLarge = 16;

/// LED status colors + semantics, matching the Angular LEDStatus enum.
enum LedStatus {
  /// No status — flat, dim, never pulses.
  off(Color(0xFF9E9E9E), 'No status'),

  /// Urgent / error.
  red(Color(0xFFF44336), 'Urgent'),

  /// High priority.
  orange(Color(0xFFFF9800), 'High priority'),

  /// Success / completed / low-priority-ok.
  green(Color(0xFF4CAF50), 'Success'),

  /// Information / normal.
  blue(Color(0xFF2196F3), 'Information'),

  /// Read / archived — dim, never pulses.
  gray(Color(0xFFBDBDBD), 'Read');

  const LedStatus(this.color, this.semanticLabel);

  /// Dot color.
  final Color color;

  /// Default accessibility label ("<label> indicator").
  final String semanticLabel;
}

/// Small circular LED indicator with optional pulse animation.
///
/// Pulse is suppressed for [LedStatus.off]/[LedStatus.gray] (they represent
/// inert states) and when the platform requests reduced motion.
class LedIndicator extends StatefulWidget {
  const LedIndicator({
    super.key,
    required this.status,
    this.size = kLedMedium,
    this.pulse = false,
    this.semanticLabel,
  });

  /// Which status to render.
  final LedStatus status;

  /// Dot diameter; see [kLedSmall]/[kLedMedium]/[kLedLarge].
  final double size;

  /// Whether to run the 2s pulse animation (gated — see class doc).
  final bool pulse;

  /// Accessibility label override; defaults to
  /// `'<status.semanticLabel> indicator'`.
  final String? semanticLabel;

  @override
  State<LedIndicator> createState() => _LedIndicatorState();
}

// TickerProviderStateMixin, NOT SingleTickerProviderStateMixin: _syncController
// disposes the controller when the pulse turns off and creates a NEW one when
// it turns back on, so a single State can legitimately create several tickers
// over its lifetime. SingleTickerProviderStateMixin permits exactly one and
// asserts on the second ("multiple tickers were created"), which fires for any
// consumer that TOGGLES `pulse` on a mounted indicator — e.g. pulsing only
// while a connection is degraded and going solid once it recovers. The
// assertion surfaces confusingly: the build throws, Flutter substitutes an
// ErrorWidget, and the ErrorWidget's huge intrinsic size blows out the
// enclosing Row/Column as a ~99k-pixel overflow that looks like a layout bug.
class _LedIndicatorState extends State<LedIndicator>
    with TickerProviderStateMixin {
  AnimationController? _controller;

  bool get _wantsPulse =>
      widget.pulse &&
      widget.status != LedStatus.off &&
      widget.status != LedStatus.gray;

  void _syncController(bool animate) {
    if (animate && _controller == null) {
      _controller = AnimationController(
        duration: const Duration(seconds: 2),
        vsync: this,
      )..repeat(reverse: true);
    } else if (!animate && _controller != null) {
      _controller?.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the platform reduced-motion preference (checked in build so it
    // reacts to live changes; disableAnimations covers "reduce motion").
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    final bool highContrast = MediaQuery.highContrastOf(context);
    final bool animate = _wantsPulse && !reducedMotion;
    _syncController(animate);

    final Widget dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.status.color,
        shape: BoxShape.circle,
        // High-contrast mode: a solid border keeps the dot legible when the
        // glow shadow washes out.
        border: highContrast
            ? Border.all(
                color: Theme.of(context).colorScheme.onSurface,
                width: 2,
              )
            : null,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: widget.status.color.withValues(alpha: 0.5),
            blurRadius: 4,
            spreadRadius: 1,
          ),
        ],
      ),
    );

    final Widget led;
    final AnimationController? c = _controller;
    if (!animate || c == null) {
      led = dot;
    } else {
      led = AnimatedBuilder(
        animation: c,
        builder: (BuildContext context, Widget? child) => Opacity(
          opacity: 0.4 + (c.value * 0.6),
          child: child,
        ),
        child: dot,
      );
    }

    return Semantics(
      label: widget.semanticLabel ?? '${widget.status.semanticLabel} indicator',
      child: led,
    );
  }
}
