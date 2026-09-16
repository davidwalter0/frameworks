// Pure text-editing helpers for babel `#+RESULTS:` insertion/replacement
// (C-c C-c / org-babel-execute-src-block). Kept separate from
// org_structure.dart since these operate on the [ResultsRange] line-span the
// Go org support binary computes rather than on heading/subtree structure —
// the seam contract (docs/design/go-support-binary-seam.org) puts "where do
// results go" on the Go side and "how the buffer text is spliced" here.
//
// No Flutter, no editor coupling — the editor widget applies the returned
// [OrgEdit] and re-paints/re-folds afterward, exactly like org_structure.dart.
library;

import '../org/org_support_client.dart' show ResultsRange;
import 'org_structure.dart' show OrgEdit;

/// Formats [output] as an org fixed-width `#+RESULTS:` block: a
/// `#+RESULTS:` line followed by each output line prefixed `: ` (the
/// classic org-babel "colon block" — no `#+begin_example` wrapping). A
/// trailing newline in [output] is dropped so it doesn't produce a spurious
/// empty last line; an empty [output] still produces the bare `#+RESULTS:`
/// line with no body lines.
List<String> formatResultsBlock(String output) {
  String body = output;
  if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
  final List<String> bodyLines =
      body.isEmpty ? const <String>[] : body.split('\n');
  return <String>['#+RESULTS:', for (final String line in bodyLines) ': $line'];
}

/// Splices a `#+RESULTS:` block for [output] into [text] at the location
/// [range] describes — replacing [range.replaceStartLine]..[range.replaceEndLine]
/// when [ResultsRange.hasExisting], otherwise inserting a fresh block at
/// [range.insertLine] — and remaps [caret] to the same (line, column) it
/// occupied before the edit.
///
/// The edit always lands strictly after the caret's line: [range] is always
/// computed from a source block that contains the caret, and results always
/// follow that block, so the caret's own line is never rewritten and its
/// column never shifts.
OrgEdit spliceResultsBlock(
  String text,
  int caret,
  ResultsRange range,
  String output,
) {
  final List<String> lines = text.split('\n');
  final int clampedCaret = caret.clamp(0, text.length);
  final int caretLine = _lineIndexOf(lines, clampedCaret);
  final int caretCol = clampedCaret - _lineStartOffset(lines, caretLine);

  final List<String> resultLines = formatResultsBlock(output);
  final List<String> newLines = List<String>.from(lines);
  if (range.hasExisting) {
    final int start = range.replaceStartLine!.clamp(0, newLines.length);
    final int end = (range.replaceEndLine! + 1).clamp(start, newLines.length);
    newLines.replaceRange(start, end, resultLines);
  } else {
    newLines.insertAll(range.insertLine.clamp(0, newLines.length), resultLines);
  }

  final String newText = newLines.join('\n');
  final int newCaret = _lineStartOffset(newLines, caretLine) + caretCol;
  return (text: newText, caret: newCaret.clamp(0, newText.length));
}

/// The 0-based index of the line containing char [offset] into the text
/// [lines] were split from (each line's length plus one for its `\n`).
int _lineIndexOf(List<String> lines, int offset) {
  int consumed = 0;
  for (int i = 0; i < lines.length; i++) {
    final int lineLenWithNl = lines[i].length + 1;
    if (offset < consumed + lineLenWithNl || i == lines.length - 1) {
      return i;
    }
    consumed += lineLenWithNl;
  }
  return lines.length - 1;
}

/// The char offset of the start of 0-based [lineIndex] within [lines]
/// joined by `\n`.
int _lineStartOffset(List<String> lines, int lineIndex) {
  int offset = 0;
  for (int i = 0; i < lineIndex && i < lines.length; i++) {
    offset += lines[i].length + 1;
  }
  return offset;
}
