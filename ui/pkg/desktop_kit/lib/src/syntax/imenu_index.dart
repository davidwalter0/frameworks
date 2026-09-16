// A pure, demo-grade `imenu`-style index over a text buffer: given a text and
// its [SyntaxLanguage], return the list of navigable entries (title + 0-based
// line number) an Emacs `imenu` popup would show for that mode. No Flutter
// dependency; language detection and per-mode regexes mirror [SyntaxFaces]
// (`emacs_faces.dart`) so the two stay visually/semantically consistent.
library;

import '../org_edit/org_fold.dart';
import 'emacs_faces.dart';

/// One imenu entry: a display [title] and the 0-based buffer [line] it jumps
/// to. `title` is pre-formatted for direct display (org entries are indented
/// by outline level, matching Emacs's nested imenu submenu convention
/// flattened to a single list for this demo).
typedef ImenuEntry = ({String title, int line});

/// Builds the imenu-style index for [text] under language [lang].
///
/// - `SyntaxLanguage.org`: every heading line, indented two spaces per
///   outline level beyond the first, title = heading text with leading stars
///   and whitespace stripped.
/// - `SyntaxLanguage.elisp`: every top-level `(defun NAME ...)` definition,
///   title = `NAME`.
/// - `SyntaxLanguage.go`: every `func NAME(...)` (including methods; the
///   receiver is not part of the title), title = `NAME`.
/// - `SyntaxLanguage.yaml`: every top-level (column-0) `key:` mapping entry,
///   title = `key`.
/// - `SyntaxLanguage.none`: always empty — no mode, no index.
List<ImenuEntry> imenuIndex(String text, SyntaxLanguage lang) {
  switch (lang) {
    case SyntaxLanguage.org:
      return _orgIndex(text);
    case SyntaxLanguage.elisp:
      return _regexIndex(text, _elispDefunRe, group: 1);
    case SyntaxLanguage.go:
      return _regexIndex(text, _goFuncRe, group: 1);
    case SyntaxLanguage.yaml:
      return _yamlIndex(text);
    case SyntaxLanguage.none:
      return const <ImenuEntry>[];
  }
}

List<ImenuEntry> _orgIndex(String text) {
  final List<String> lines = text.split('\n');
  final List<ImenuEntry> out = <ImenuEntry>[];
  for (final OrgHeading h in OrgFold.headings(text)) {
    final String raw = lines[h.line];
    // Strip the leading stars + exactly one separating space (mirrors
    // OrgFold._headingLevel's definition of a heading line).
    final String title = raw.substring(h.level + 1).trimRight();
    out.add((title: '  ' * (h.level - 1) + title, line: h.line));
  }
  return out;
}

// (defun NAME ...) — same shape as SyntaxFaces._elispDefunNameRe, anchored to
// the start of a (possibly indented) line so nested `defun`s inside a `let`
// body aren't picked up as separate top-level entries.
// NOTE: leading indentation uses `[ \t]*`, not `\s*` — `\s` also matches
// `\n`, and with `multiLine: true` a greedy `\s*` can swallow a preceding
// blank line so the match (and its computed line number) anchors one line
// too early.
final RegExp _elispDefunRe =
    RegExp(r'^[ \t]*\(defun\s+([A-Za-z_][\w\-/!?*]*)', multiLine: true);

// func NAME(...) or func (recv Type) NAME(...) — title is always NAME, never
// the receiver. Matches SyntaxFaces._goFuncNameRe's identifier shape.
final RegExp _goFuncRe = RegExp(
  r'^[ \t]*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(',
  multiLine: true,
);

List<ImenuEntry> _regexIndex(String text, RegExp re, {required int group}) {
  final List<ImenuEntry> out = <ImenuEntry>[];
  int line = 0;
  int scanned = 0;
  for (final RegExpMatch m in re.allMatches(text)) {
    // Matches are yielded in increasing [start] order, so we only ever scan
    // each character of [text] once across the whole loop (amortized O(n)).
    while (scanned < m.start) {
      if (text.codeUnitAt(scanned) == 0x0A) line++;
      scanned++;
    }
    out.add((title: m.group(group)!, line: line));
  }
  return out;
}

// A top-level (column-0) `key:` mapping entry — not a list item (`- key:`),
// not nested under another key (indented), and not a comment.
final RegExp _yamlKeyRe = RegExp(r'^([A-Za-z_][\w-]*)\s*:');

List<ImenuEntry> _yamlIndex(String text) {
  final List<String> lines = text.split('\n');
  final List<ImenuEntry> out = <ImenuEntry>[];
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? m = _yamlKeyRe.firstMatch(lines[i]);
    if (m != null) out.add((title: m.group(1)!, line: i));
  }
  return out;
}
