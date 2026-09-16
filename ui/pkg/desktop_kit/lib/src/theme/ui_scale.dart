// A single top-level helper, [applyUiScale], that wires an
// [AppearanceSettings.uiScale] (or [DisplayConfig.uiScale]) value into an
// actual, running widget tree. Kept standalone and dependency-free (just
// `flutter/material.dart`) so it drops into `MaterialApp.builder` unchanged.
library;

import 'package:flutter/material.dart';

/// The ambient icon size assumed when no [IconTheme] is already in scope —
/// Material's own default (`IconThemeData.size` defaults to 24.0).
const double _kDefaultIconSize = 24.0;

/// Applies a desktop UI zoom factor [scale] to [child].
///
/// This is a **pragmatic** desktop zoom, not a geometric one: it scales *text*
/// (via [TextScaler.linear]) and the *ambient icon size* (via [IconTheme]), but
/// it does NOT wrap [child] in a [Transform.scale] or otherwise resize layout
/// geometry, containers, paddings, or images. That keeps the result crisp
/// (no blurry raster upscaling, no clipped/overflowing hit-test regions) at the
/// cost of not scaling everything — the trade-off desktop apps typically want
/// when a user asks to "zoom the UI": bigger, more legible text and icons, not
/// a literal magnifying glass over fixed layout.
///
/// When [scale] is exactly `1.0` the wrapper is a NO-OP rather than absent:
/// the [MediaQuery] re-publishes the ambient data unchanged (so an OS
/// accessibility text factor still passes through untouched) and the
/// [IconTheme] re-publishes the ambient icon size. The nodes are still
/// inserted, and that is deliberate — see below.
///
/// ## Why 1.0 does not take a shortcut
///
/// The obvious `if (scale == 1.0) return child;` is a silent data-loss bug,
/// not an optimization. Flutter reconciles a slot by `(runtimeType, key)`, so
/// returning [child] bare at 1.0 and wrapped otherwise puts two structurally
/// different widgets in one slot: crossing 1.0 in either direction disposes
/// the entire subtree and inflates a fresh one, discarding every State object
/// in it. This helper is documented to wrap `MaterialApp.builder`'s child —
/// the app's [Navigator] — so the shortcut threw away the whole route stack,
/// and any unsaved work its pages held, the moment a user nudged the zoom
/// slider off (or back to) its default. Nothing looked wrong afterwards; the
/// app had simply rebuilt itself from nothing. Same defect, and same remedy —
/// a constant tree shape — as `SpanHost` (`src/layout/span_host.dart`).
///
/// The cost is two inert inherited nodes at 1.0, and that [MediaQuery] must
/// now be in scope for every [scale], not only for `!= 1.0`.
///
/// For any [scale], wraps [child] in:
///  * a [MediaQuery] that copies [MediaQuery.of] and overrides
///    [MediaQueryData.textScaler] to `TextScaler.linear(scale)`, so every
///    descendant [Text] (and anything else reading the ambient text scaler)
///    grows/shrinks with [scale];
///  * an [IconTheme] that scales the *ambient* icon size — the current
///    [IconTheme.of] size (falling back to Material's 24.0 default) multiplied
///    by [scale] — so unsized [Icon]/[IconButton] widgets scale in step with
///    the text.
///
/// Intended usage — wrap the whole app once, in `MaterialApp.builder`, driven
/// by the app's persisted [AppearanceSettings.uiScale]:
/// ```dart
/// MaterialApp(
///   // ...
///   builder: (BuildContext context, Widget? child) =>
///       applyUiScale(context, appearance.uiScale, child!),
/// )
/// ```
Widget applyUiScale(BuildContext context, double scale, Widget child) {
  final MediaQueryData mediaQuery = MediaQuery.of(context);
  final double baseIconSize = IconTheme.of(context).size ?? _kDefaultIconSize;
  return MediaQuery(
    // At 1.0 the ambient scaler is republished AS IS, not overwritten with
    // TextScaler.linear(1.0): the override semantics (documented in
    // docs/accessibility-signal-findings.org) must stay confined to a scale
    // the user actually asked for, or a default slider position would start
    // discarding the OS text-scaling factor.
    data: scale == 1.0
        ? mediaQuery
        : mediaQuery.copyWith(textScaler: TextScaler.linear(scale)),
    child: IconTheme.merge(
      // `baseIconSize * 1.0` is the ambient size, so this is a no-op at 1.0.
      data: IconThemeData(size: baseIconSize * scale),
      child: child,
    ),
  );
}
