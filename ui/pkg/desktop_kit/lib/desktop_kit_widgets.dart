/// Reusable widgets for the `desktop_kit` package.
///
/// Exports:
/// - [AutoHideBottomBar]    — auto-hiding, pull-up bottom bar; wraps a
///                            scrollable body and a bar (e.g. [NavigationBar])
///                            with scroll-driven show/hide and an optional
///                            inactivity timer.
/// - [collapseTilde]        — pure helper: replaces leading `$HOME` with `~`.
/// - [ExpandCollapseAllBar] — two-button toolbar for bulk expand / collapse.
/// - [FileRef]              — controlled path-display widget with optional
///                            copy-path and reveal-in-file-manager actions.
/// - [Foldable]             — controlled fold/expand with optional async
///                            lazy-load spinner.
library;

export 'src/widgets/auto_hide_bottom_bar.dart' show AutoHideBottomBar;
export 'src/widgets/file_ref.dart' show FileRef, collapseTilde;
export 'src/widgets/foldable.dart' show ExpandCollapseAllBar, Foldable;
