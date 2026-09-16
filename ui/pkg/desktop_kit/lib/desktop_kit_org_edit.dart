/// Pure org-mode text editing for desktop_kit — heading/subtree structure,
/// tables, outline folding, and babel `#+RESULTS:` splicing, all operating on
/// a plain Dart `String` with no Flutter dependency.
///
/// Kept separate from `desktop_kit_org.dart` (the `orgsupport` Go-binary
/// client, `dart:io`-coupled) because this module is pure editing logic that
/// works anywhere, including web — the same split the kit already draws
/// between the kana engine and the Anthy IME driver.
///
/// Includes:
/// - [OrgStructure] / [OrgEdit] — heading/subtree structure edits
/// - [OrgTable] — table alignment and cell editing
/// - [OrgOutline] — outline folding/visibility state
/// - org fold state ([OrgFoldState] and friends)
/// - [formatResultsBlock] / [spliceResultsBlock] — babel `#+RESULTS:` block
///   insertion/replacement (C-c C-c), using the [ResultsRange] the
///   `orgsupport` binary computes (see `desktop_kit_org.dart`)
///
/// Opt-in, like the anthy/kana bridges: NOT re-exported from `desktop_kit.dart`.
library;

export 'src/org_edit/babel_edit.dart';
export 'src/org_edit/org_fold.dart';
export 'src/org_edit/org_outline.dart';
export 'src/org_edit/org_structure.dart';
// `org_table.dart`'s own `OrgEdit` typedef is hidden here: it is a
// deliberate self-contained duplicate of `org_structure.dart`'s `OrgEdit`
// (same `({String text, int caret})` shape, kept local so `org_table.dart`
// never has to import `org_structure.dart`) — re-exporting both from one
// library would be an ambiguous export. The two typedefs alias the exact
// same record type, so callers use the unprefixed `OrgEdit` from
// `org_structure.dart` for both.
export 'src/org_edit/org_table.dart' hide OrgEdit;
