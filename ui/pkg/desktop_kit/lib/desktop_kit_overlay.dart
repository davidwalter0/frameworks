/// Modal overlay widgets for the `desktop_kit` package.
///
/// Exports:
/// - [SlideEdge]         — which screen edge a [SlideOverPanel] opens from.
/// - [SlideOverPanel]    — the panel widget (edge-anchored, size-clamped,
///                         scrollable, Escape-to-close).
/// - [showSlideOverPanel]— pushes a [SlideOverPanel] as a proper modal
///                         route (never a hand-inserted `OverlayEntry` — see
///                         that function's doc for why that distinction is
///                         load-bearing).
library;

export 'src/overlay/slide_over_panel.dart';
