// Pure rendering + addressing for the `*Buffer List*` buffer presentation of
// `C-x C-b` (Emacs `list-buffers` / Buffer Menu). No Flutter, no IO — the
// widget layer owns an [EmacsBuffer] into which [renderBufferMenu]'s text is
// inserted, and maps the caret line back to a buffer name via the same row
// order (see [kBufferMenuHeaderLines]).
library;

/// How the buffer list (`C-x C-b`) is presented.
enum BufferListStyle {
  /// A read-only `*Buffer List*` editor buffer, Emacs `list-buffers` style:
  /// navigable (n/p), RET/o visits the buffer at point, k kills it, g
  /// refreshes, q returns to the buffer you came from.
  buffer,

  /// A modal popup dialog with per-row Switch / Kill buttons.
  popup,
}

/// One row of the buffer menu — structurally identical to
/// `EmacsBuffer.bufferSnapshots()`'s element type, so a snapshot list can be
/// passed straight through (optionally filtered to drop the menu itself).
typedef BufferMenuRow = ({
  String name,
  bool current,
  int lineCount,
  int byteCount,
});

/// Number of header lines [renderBufferMenu] emits before the first buffer
/// row (a column-title line and a rule line). The entry index of caret line
/// `n` (0-based) is `n - kBufferMenuHeaderLines`; negative means the caret is
/// on the header.
const int kBufferMenuHeaderLines = 2;

/// The name column width; long names overflow it (never truncated — a name
/// you cannot read in full is worse than a ragged column).
const int _kNameWidth = 34;

String _padName(String s) =>
    s.length >= _kNameWidth ? s : s.padRight(_kNameWidth);

/// Width of the numeric columns (Lines, Bytes), right-aligned.
const int _kNumWidth = 9;

/// Right-align a numeric-column cell (a count, or a header/rule label).
String _col(Object cell) => cell.toString().padLeft(_kNumWidth);

/// Render the `*Buffer List*` buffer text for [rows].
///
/// Layout (column 0 is the current-buffer marker `.`):
/// ```
///   Buffer                                 Lines     Bytes
///   ------                                 -----     -----
/// . scratch.org                              120      3840
///   *shell*                                   45      1012
/// ```
/// Line 0/1 are the header ([kBufferMenuHeaderLines]); line `2 + i` is
/// `rows[i]`, so a caret on line `L` addresses `rows[L - 2]`.
String renderBufferMenu(List<BufferMenuRow> rows) {
  final StringBuffer b = StringBuffer()
    ..writeln('  ${_padName('Buffer')}${_col('Lines')}${_col('Bytes')}')
    ..write('  ${_padName('------')}${_col('-----')}${_col('-----')}');
  for (final BufferMenuRow r in rows) {
    b.write('\n${r.current ? '.' : ' '} '
        '${_padName(r.name)}${_col(r.lineCount)}${_col(r.byteCount)}');
  }
  return b.toString();
}

/// The name of the buffer addressed by 0-based [caretLine] over a menu that
/// listed [rows] in order, or null when the caret is on a header line or past
/// the last row. Pure inverse of [renderBufferMenu]'s row ordering — the
/// widget keeps the same [rows] it rendered and calls this to resolve RET / k.
String? bufferMenuNameAt(List<BufferMenuRow> rows, int caretLine) {
  final int i = caretLine - kBufferMenuHeaderLines;
  if (i < 0 || i >= rows.length) return null;
  return rows[i].name;
}
