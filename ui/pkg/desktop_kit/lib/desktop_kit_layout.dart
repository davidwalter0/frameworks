/// Layout primitives: the controlled master-detail [AdaptiveLayout] (three
/// modes — side-by-side / overlay / full-width — with drag-resizable panes),
/// the [ResizeHandle] divider, and the pinned resizable [SpanHost] /
/// [SpanPane] / [SpanDragHandle] span panes (top/bottom strips,
/// layout-integrated — the `topSpan`/`bottomSpan` presentation modes).
///
/// All controlled (value + onChanged): the host owns mode, fractions, span
/// state and persistence. No state-management dependency.
library desktop_kit_layout;

export 'src/layout/adaptive_layout.dart';
export 'src/layout/resize_handle.dart';
export 'src/layout/span_host.dart';
