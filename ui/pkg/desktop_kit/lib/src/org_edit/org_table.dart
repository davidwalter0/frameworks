// Pure org table-editing operations over (text, caret).
//
// Each function below takes the buffer text and a caret (buffer offset) and
// returns a new (text, caret) pair. No Flutter, no editor coupling — the
// editor widget calls these and re-paints afterward. Follows the same
// conventions as org_structure.dart (`OrgEdit` result, `_lineStarts` /
// `_lineAt` helpers), replicated here rather than shared since those
// helpers are private there.
//
// NOTE on width: column widths below are computed in *code units*
// (`String.length`), i.e. ASCII/narrow-glyph width. Real org-mode uses
// `string-width` semantics where CJK / fullwidth characters occupy two
// display columns; that distinction is NOT modeled here — a table with
// wide (CJK) cell content will still align by code-unit count, which can
// look visually ragged in a monospace terminal that renders those glyphs
// double-wide. Fixing this would require a display-width table (similar to
// wcwidth) that this module intentionally does not pull in.
library;

/// A pure (text, caret) result — every op in this file returns one of these.
typedef OrgEdit = ({String text, int caret});

/// The buffer offset each line starts at (`starts[i]` = offset of line `i`).
List<int> _lineStarts(String text) {
  final List<int> starts = <int>[0];
  for (int i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  return starts;
}

/// The line index containing buffer offset [caret], given [starts].
int _lineAt(List<int> starts, int caret) {
  for (int i = starts.length - 1; i >= 0; i--) {
    if (starts[i] <= caret) return i;
  }
  return 0;
}

/// Whether [line] is a table row: after stripping leading whitespace, it
/// starts with `|`.
bool isTableLine(String line) => line.trimLeft().startsWith('|');

/// Whether [line] is a table SEPARATOR row (`|---+---|`-style): a table line
/// whose non-whitespace content is made up only of `|`, `-`, and `+`.
bool isSeparatorLine(String line) {
  final String t = line.trim();
  if (!t.startsWith('|')) return false;
  for (int i = 0; i < t.length; i++) {
    final String c = t[i];
    if (c != '|' && c != '-' && c != '+') return false;
  }
  return true;
}

/// Split a data row line into its raw (untrimmed) cell segments, dropping
/// the leading/trailing empty segments produced by the bounding `|`
/// characters. `"| a | bb |"` -> `[" a ", " bb "]`.
List<String> _rawCells(String line) {
  final List<String> parts = line.split('|');
  // parts[0] is whatever precedes the first '|' (indentation, normally
  // empty once trimmed); parts.last is whatever follows the last '|'.
  const int start = 1;
  int end = parts.length;
  if (end > start && parts[end - 1].trim().isEmpty) end -= 1;
  if (end <= start) return <String>[];
  return parts.sublist(start, end);
}

/// Whether the caret's line (see [caret] mapped via [starts]/[lines]) is a
/// table row.
bool isTableLineAt(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  return isTableLine(lines[li]);
}

/// The [start, end) line-index range of the contiguous table that the
/// caret's line belongs to (table lines directly above/below the caret's
/// line, stopping at the first non-table line). Empty range `(li, li)` when
/// the caret's line is not itself a table line.
({int start, int end}) tableLineRange(List<String> lines, int li) {
  if (li < 0 || li >= lines.length || !isTableLine(lines[li])) {
    return (start: li, end: li);
  }
  int start = li;
  while (start > 0 && isTableLine(lines[start - 1])) {
    start--;
  }
  int end = li + 1;
  while (end < lines.length && isTableLine(lines[end])) {
    end++;
  }
  return (start: start, end: end);
}

/// Column widths (max trimmed-cell length per column, across all DATA rows
/// in `lines[start, end)`; separator rows don't contribute).
List<int> _columnWidths(List<String> lines, int start, int end) {
  final List<int> widths = <int>[];
  for (int i = start; i < end; i++) {
    if (isSeparatorLine(lines[i])) continue;
    final List<String> cells = _rawCells(lines[i]);
    for (int c = 0; c < cells.length; c++) {
      final int w = cells[c].trim().length;
      if (c >= widths.length) {
        widths.add(w);
      } else if (w > widths[c]) {
        widths[c] = w;
      }
    }
  }
  return widths;
}

/// Render a single data row from trimmed [cells], padded to [widths].
String _renderDataRow(List<String> cells, List<int> widths) {
  final StringBuffer sb = StringBuffer('|');
  for (int c = 0; c < widths.length; c++) {
    final String cell = c < cells.length ? cells[c] : '';
    sb.write(' ');
    sb.write(cell.padRight(widths[c]));
    sb.write(' |');
  }
  return sb.toString();
}

/// Render a separator row matching column [widths].
String _renderSeparatorRow(List<int> widths) {
  final StringBuffer sb = StringBuffer('|');
  for (int c = 0; c < widths.length; c++) {
    sb.write('-' * (widths[c] + 2));
    sb.write(c == widths.length - 1 ? '|' : '+');
  }
  return sb.toString();
}

/// Locate the caret's logical position within its table row: which column
/// it's in, and its character offset within that column's TRIMMED cell
/// content (clamped into range). Returns column -1 when the line has no
/// cells (shouldn't normally happen for a table line) or the caret sits
/// before/at the leading `|`.
({int column, int offsetInCell}) _caretCellPosition(
  String line,
  int caretCol,
) {
  final List<String> parts = line.split('|');
  // parts[0] covers columns [0, parts[0].length); the '|' at that boundary
  // is column parts[0].length; parts[1] (cell 0) covers the next segment,
  // and so on. Walk the same partition _rawCells uses.
  int pos = parts[0].length; // end of the pre-'|' segment
  if (parts.length <= 1) return (column: -1, offsetInCell: 0);
  final int cellCount = _rawCells(line).length;
  for (int c = 0; c < cellCount; c++) {
    final String raw = parts[c + 1];
    final int segStart = pos + 1; // skip the '|' itself
    final int segEnd = segStart + raw.length;
    if (caretCol <= segEnd || c == cellCount - 1) {
      // Map caretCol (clamped into this raw segment) to an offset within
      // the TRIMMED cell content.
      final int trimmedLeadLen = raw.length - raw.trimLeft().length;
      final String trimmed = raw.trim();
      final int withinRaw = (caretCol - segStart).clamp(0, raw.length);
      final int withinTrimmed =
          (withinRaw - trimmedLeadLen).clamp(0, trimmed.length);
      return (column: c, offsetInCell: withinTrimmed);
    }
    pos = segEnd;
  }
  return (column: cellCount - 1, offsetInCell: 0);
}

/// The column offset (within a re-rendered data row) of trimmed-cell
/// [offsetInCell] chars into column [column], given [widths]. Each rendered
/// cell is `' ' + padded(width) + ' ' + '|'` (width + 3 chars including its
/// trailing separating `|`); the row's leading `|` is one extra char.
int _columnOffsetInRenderedRow(int column, int offsetInCell, List<int> widths) {
  int pos = 1; // after the leading '|'
  for (int c = 0; c < column; c++) {
    pos += widths[c] + 3; // ' ' cell ' ' '|'
  }
  pos += 1; // leading ' ' of the target cell
  return pos + offsetInCell.clamp(0, widths[column]);
}

/// Recompute column widths and re-render every line in the table containing
/// [caret]'s line, keeping [caret] anchored to the same logical cell/offset.
/// A no-op (`text` unchanged) when the caret's line is not a table line.
OrgEdit alignTable(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  if (li >= lines.length || !isTableLine(lines[li])) {
    return (text: text, caret: caret);
  }
  final ({int start, int end}) range = tableLineRange(lines, li);
  final List<int> widths = _columnWidths(lines, range.start, range.end);
  if (widths.isEmpty) return (text: text, caret: caret);

  // Locate the caret's logical cell before any line is rewritten.
  final int caretCol = caret - starts[li];
  final ({int column, int offsetInCell}) pos =
      _caretCellPosition(lines[li], caretCol);

  final List<String> newLines = List<String>.from(lines);
  for (int i = range.start; i < range.end; i++) {
    if (isSeparatorLine(lines[i])) {
      newLines[i] = _renderSeparatorRow(widths);
    } else {
      final List<String> cells =
          _rawCells(lines[i]).map((String c) => c.trim()).toList();
      newLines[i] = _renderDataRow(cells, widths);
    }
  }
  final String newText = newLines.join('\n');

  int newCaret;
  if (pos.column < 0) {
    // Caret was before the first '|' on its line; keep it at the line
    // start.
    final List<int> newStarts = _lineStarts(newText);
    newCaret = newStarts[li];
  } else {
    final List<int> newStarts = _lineStarts(newText);
    final int col = _columnOffsetInRenderedRow(
      pos.column.clamp(0, widths.length - 1),
      pos.offsetInCell,
      widths,
    );
    newCaret = newStarts[li] + col;
  }
  return (text: newText, caret: newCaret);
}

/// TAB semantics: move the caret to the start of the next cell in reading
/// order (left-to-right, then down a row), skipping separator rows. On the
/// LAST cell of the LAST row of the table, a fresh empty data row is
/// appended (like org's `org-table-next-field`) and the caret lands in its
/// first cell. Re-aligns the table first so widths/offsets are current.
/// No-op (returns [alignTable]'s result unchanged) when the caret's line is
/// not a table line.
OrgEdit nextCell(String text, int caret) {
  final OrgEdit aligned = alignTable(text, caret);
  final List<String> lines = aligned.text.split('\n');
  final List<int> starts = _lineStarts(aligned.text);
  final int li = _lineAt(starts, aligned.caret);
  if (li >= lines.length || !isTableLine(lines[li])) return aligned;

  final ({int start, int end}) range = tableLineRange(lines, li);
  final List<int> widths = _columnWidths(lines, range.start, range.end);
  if (widths.isEmpty) return aligned;

  final int caretCol = aligned.caret - starts[li];
  final ({int column, int offsetInCell}) pos =
      _caretCellPosition(lines[li], caretCol);
  final int fromColumn = pos.column < 0 ? 0 : pos.column;

  // Find the next data-row line index (skip separators) starting at li,
  // and the next column (fromColumn+1, or 0 on the next data row).
  int targetLine = li;
  int targetColumn = fromColumn + 1;
  if (targetColumn >= widths.length) {
    targetColumn = 0;
    targetLine = li + 1;
    while (targetLine < range.end && isSeparatorLine(lines[targetLine])) {
      targetLine++;
    }
    if (targetLine >= range.end) {
      // Off the end of the table: append a fresh empty data row.
      final String newRow = _renderDataRow(<String>[], widths);
      final int insertAt = starts[range.end - 1] + lines[range.end - 1].length;
      final String newText =
          '${aligned.text.substring(0, insertAt)}\n$newRow${aligned.text.substring(insertAt)}';
      final int rowStart = insertAt + 1;
      final int col = _columnOffsetInRenderedRow(0, 0, widths);
      return (text: newText, caret: rowStart + col);
    }
  }
  final int col = _columnOffsetInRenderedRow(targetColumn, 0, widths);
  return (text: aligned.text, caret: starts[targetLine] + col);
}

/// Shift-TAB semantics: move the caret to the start of the previous cell in
/// reading order (right-to-left, then up a row), skipping separator rows.
/// A no-op at the table's first cell. Re-aligns the table first.
OrgEdit prevCell(String text, int caret) {
  final OrgEdit aligned = alignTable(text, caret);
  final List<String> lines = aligned.text.split('\n');
  final List<int> starts = _lineStarts(aligned.text);
  final int li = _lineAt(starts, aligned.caret);
  if (li >= lines.length || !isTableLine(lines[li])) return aligned;

  final ({int start, int end}) range = tableLineRange(lines, li);
  final List<int> widths = _columnWidths(lines, range.start, range.end);
  if (widths.isEmpty) return aligned;

  final int caretCol = aligned.caret - starts[li];
  final ({int column, int offsetInCell}) pos =
      _caretCellPosition(lines[li], caretCol);
  final int fromColumn = pos.column < 0 ? 0 : pos.column;

  int targetLine = li;
  int targetColumn = fromColumn - 1;
  if (targetColumn < 0) {
    targetColumn = widths.length - 1;
    targetLine = li - 1;
    while (targetLine >= range.start && isSeparatorLine(lines[targetLine])) {
      targetLine--;
    }
    if (targetLine < range.start) {
      // Already at the table's first cell: no-op.
      final int col = _columnOffsetInRenderedRow(fromColumn, 0, widths);
      return (text: aligned.text, caret: starts[li] + col);
    }
  }
  final int col = _columnOffsetInRenderedRow(targetColumn, 0, widths);
  return (text: aligned.text, caret: starts[targetLine] + col);
}

/// RET semantics: move the caret to the SAME column of the next data row
/// (skipping separator rows), re-aligning the table first. On the LAST data
/// row of the table, a fresh empty data row is appended (like
/// `org-table-next-row`) and the caret lands in that row's same column. A
/// no-op (returns [alignTable]'s result unchanged) when the caret's line is
/// not a table line.
OrgEdit cellBelow(String text, int caret) {
  final OrgEdit aligned = alignTable(text, caret);
  final List<String> lines = aligned.text.split('\n');
  final List<int> starts = _lineStarts(aligned.text);
  final int li = _lineAt(starts, aligned.caret);
  if (li >= lines.length || !isTableLine(lines[li])) return aligned;

  final ({int start, int end}) range = tableLineRange(lines, li);
  final List<int> widths = _columnWidths(lines, range.start, range.end);
  if (widths.isEmpty) return aligned;

  final int caretCol = aligned.caret - starts[li];
  final ({int column, int offsetInCell}) pos =
      _caretCellPosition(lines[li], caretCol);
  final int column =
      (pos.column < 0 ? 0 : pos.column).clamp(0, widths.length - 1);

  int targetLine = li + 1;
  while (targetLine < range.end && isSeparatorLine(lines[targetLine])) {
    targetLine++;
  }
  if (targetLine >= range.end) {
    // Off the end of the table: append a fresh empty data row.
    final String newRow = _renderDataRow(<String>[], widths);
    final int insertAt = starts[range.end - 1] + lines[range.end - 1].length;
    final String newText =
        '${aligned.text.substring(0, insertAt)}\n$newRow${aligned.text.substring(insertAt)}';
    final int rowStart = insertAt + 1;
    final int col = _columnOffsetInRenderedRow(column, 0, widths);
    return (text: newText, caret: rowStart + col);
  }
  final int col = _columnOffsetInRenderedRow(column, 0, widths);
  return (text: aligned.text, caret: starts[targetLine] + col);
}

/// Insert a fresh empty data row directly below the caret's row (aligning
/// the table first), with the caret landing in the new row's first cell.
/// No-op when the caret's line is not a table line.
OrgEdit newRowBelow(String text, int caret) {
  final OrgEdit aligned = alignTable(text, caret);
  final List<String> lines = aligned.text.split('\n');
  final List<int> starts = _lineStarts(aligned.text);
  final int li = _lineAt(starts, aligned.caret);
  if (li >= lines.length || !isTableLine(lines[li])) return aligned;

  final ({int start, int end}) range = tableLineRange(lines, li);
  final List<int> widths = _columnWidths(lines, range.start, range.end);
  if (widths.isEmpty) return aligned;

  final String newRow = _renderDataRow(<String>[], widths);
  final int insertAt = starts[li] + lines[li].length;
  final String newText =
      '${aligned.text.substring(0, insertAt)}\n$newRow${aligned.text.substring(insertAt)}';
  final int rowStart = insertAt + 1;
  final int col = _columnOffsetInRenderedRow(0, 0, widths);
  return (text: newText, caret: rowStart + col);
}
