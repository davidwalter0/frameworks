/// Language-aware syntax highlighting + imenu for desktop_kit.
///
/// Pure, Flutter-free: [FaceSpan]s describe *what* to highlight over a plain
/// Dart `String`; a host widget maps [Face] to actual colors (e.g. via
/// `faceToThemeSlot`) and imenu entries to a jump-to-heading UI. Reusable
/// without the buffer engine (`desktop_kit_editor.dart`).
///
/// Includes:
/// - [SyntaxLanguage] / [FaceSpan] / [Face] / [faceToThemeSlot] — the
///   highlighting model
/// - [ImenuIndex] / imenu entry types — a language- and org-fold-aware
///   "jump to definition/heading" index
///
/// Opt-in, like the anthy/kana bridges: NOT re-exported from `desktop_kit.dart`.
library;

export 'src/syntax/emacs_faces.dart';
export 'src/syntax/imenu_index.dart';
