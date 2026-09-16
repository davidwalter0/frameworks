// The ξ (xi) glyph widget — the structural inspiration for the GNU Emacs
// ribbon loop.
//
// Unified from:
//   - notekeep `lib/src/widgets/xi_glyph.dart` (fontFamilyFallback, height 1.0,
//     textAlign, ambient IconTheme color)
//   - voicelab `lib/widgets/emacs_xi_icon.dart` (fontWeight w600, IconTheme
//     opacity handling)
library;

import 'package:flutter/widgets.dart';

/// A scalable, theme-colored glyph icon rendered from the Greek small letter
/// xi (ξ, U+03BE) — the structural inspiration for the GNU Emacs logo's
/// ribbon loop.
///
/// Behaves like an [Icon]: size and color default to the ambient [IconTheme],
/// so it follows the app's colour settings (seed / foreground override) plus
/// any per-state tint the surrounding [IconTheme] conveys — e.g. selected vs.
/// unselected inside a [SegmentedButton], or the dimmed colour of a disabled
/// [IconButton].
///
/// The Greek stroke is thin at the default weight; [FontWeight.w600] keeps the
/// glyph visually present at icon sizes. [fontFamilyFallback] ensures the
/// character renders even when the primary font lacks it.
class XiGlyph extends StatelessWidget {
  /// Create a [XiGlyph].
  const XiGlyph({super.key, this.size, this.color});

  /// Glyph size in logical pixels. Defaults to the ambient [IconTheme] size
  /// (falling back to 24) so it matches Material icons around it.
  final double? size;

  /// Glyph colour. Defaults to the ambient [IconTheme] color (respecting
  /// opacity).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24.0;
    final resolvedColor = color ?? iconTheme.color;
    final opacity = iconTheme.opacity ?? 1.0;
    final effectiveColor = (color == null && opacity < 1.0)
        ? resolvedColor?.withValues(alpha: opacity)
        : resolvedColor;
    return Text(
      'ξ',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: resolvedSize,
        color: effectiveColor,
        height: 1.0,
        fontWeight: FontWeight.w600,
        fontFamilyFallback: const ['Noto Sans', 'DejaVu Sans', 'sans-serif'],
      ),
    );
  }
}
