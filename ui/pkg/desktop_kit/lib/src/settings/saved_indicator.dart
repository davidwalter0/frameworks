// "Saved ✓" flash widget — listens to a [ValueListenable<DateTime?>] and
// shows an animated row that fades in on write then fades back out after a
// short hold.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Displays an animated "Saved ✓" row that appears whenever [savedAt] emits a
/// non-null value, then fades out after [holdDuration].
///
/// Controlled widget: the caller owns the [ValueListenable] (typically
/// [SettingsStore.savedAt]) and this widget only observes it — no internal
/// state management dependency is introduced.
///
/// ```dart
/// SavedIndicator(savedAt: store.savedAt)
/// ```
class SavedIndicator extends StatefulWidget {
  /// Creates a [SavedIndicator] that listens to [savedAt].
  const SavedIndicator({
    super.key,
    required this.savedAt,
    this.holdDuration = const Duration(seconds: 2),
    this.fadeDuration = const Duration(milliseconds: 400),
    this.label = 'Saved ✓',
  });

  /// Emits the timestamp of each successful write; `null` means never saved.
  final ValueListenable<DateTime?> savedAt;

  /// How long the indicator stays fully visible before fading out.
  final Duration holdDuration;

  /// Duration of the fade-in and fade-out animations.
  final Duration fadeDuration;

  /// Text label shown in the indicator row.
  final String label;

  @override
  State<SavedIndicator> createState() => _SavedIndicatorState();
}

class _SavedIndicatorState extends State<SavedIndicator> {
  double _opacity = 0.0;
  DateTime? _lastSeen;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    widget.savedAt.addListener(_onSavedAt);
  }

  @override
  void didUpdateWidget(SavedIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.savedAt != widget.savedAt) {
      oldWidget.savedAt.removeListener(_onSavedAt);
      widget.savedAt.addListener(_onSavedAt);
    }
  }

  @override
  void dispose() {
    widget.savedAt.removeListener(_onSavedAt);
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onSavedAt() {
    final ts = widget.savedAt.value;
    if (ts == null || ts == _lastSeen) return;
    _lastSeen = ts;

    _holdTimer?.cancel();
    if (mounted) setState(() => _opacity = 1.0);

    _holdTimer = Timer(widget.holdDuration, () {
      if (mounted) setState(() => _opacity = 0.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: _opacity,
      duration: widget.fadeDuration,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: cs.primary),
          const SizedBox(width: 4),
          Text(
            widget.label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.primary),
          ),
        ],
      ),
    );
  }
}
