// Pure Emacs-style editing operations: every entry point takes a plain Dart
// String plus a caret offset and returns the new text and caret — no Flutter
// dependency, no mutable state, nothing to dispose. The host (EmacsBuffer or a
// widget) owns the kill ring and simply pushes whatever `killed` comes back.
//
// Word boundaries are delegated to `TextMotions` so M-t here agrees with M-f /
// M-b elsewhere in the kit.
library;

import '../keymap/text_motions.dart';

/// Pure Emacs editing commands that are more than a motion but less than a
/// buffer: comment toggling, zapping, transposition, line jumps, rectangles.
class EditOps {
  EditOps._();

  // ---------------------------------------------------------------- helpers

  /// 0-indexed line number containing [offset].
  static int _lineOf(String text, int offset) {
    final i = offset.clamp(0, text.length);
    var line = 0;
    for (var j = 0; j < i; j++) {
      if (text.codeUnitAt(j) == 0x0A) line++;
    }
    return line;
  }

  /// Offset of the first character of 0-indexed [line]. Clamped to the last
  /// line when [line] runs past the end.
  static int _startOfLine(String text, int line) {
    if (line <= 0) return 0;
    var offset = 0;
    var seen = 0;
    while (seen < line) {
      final nl = text.indexOf('\n', offset);
      if (nl < 0) return offset; // Past the last line — clamp to its start.
      offset = nl + 1;
      seen++;
    }
    return offset;
  }

  /// Offset of `(line, column)` where both are 0-indexed and the column is
  /// clamped to the length of that line.
  static int _offsetAt(String text, int line, int column) {
    final start = _startOfLine(text, line);
    final end = TextMotions.lineEnd(text, start);
    return start + column.clamp(0, end - start);
  }

  /// Mirrors `TextMotions`' private word-char rule (letters, digits, `_`, and
  /// any non-ASCII) so the spans found here line up with M-f / M-b.
  static bool _isWordChar(int c) {
    final isDigit = c >= 0x30 && c <= 0x39;
    final isUpper = c >= 0x41 && c <= 0x5A;
    final isLower = c >= 0x61 && c <= 0x7A;
    return isDigit || isUpper || isLower || c == 0x5F || c > 0x7F;
  }

  /// The span `[start, end)` of the next word at/after [from], or null when
  /// no word remains. A caret *inside* a word yields that whole word.
  static List<int>? _wordAt(String text, int from) {
    final end = TextMotions.forwardWord(text, from);
    // forwardWord also stops at the end of the text having consumed only
    // non-word chars ("foo   " from 3) — that is *not* a word.
    if (end == from || !_isWordChar(text.codeUnitAt(end - 1))) return null;
    return [TextMotions.backwardWord(text, end), end];
  }

  // ------------------------------------------------------------- commentDwim

  /// M-; — toggle a `"$lineComment "` prefix on the caret's line.
  ///
  /// The prefix goes in after any leading indentation (as Emacs does). When
  /// the line already carries the token, the token and one following space
  /// are removed. The caret rides along with the text it sits after.
  static ({String text, int caret}) commentDwim(
    String text,
    int caret,
    String lineComment,
  ) {
    final i = caret.clamp(0, text.length);
    if (lineComment.isEmpty) return (text: text, caret: i);
    final start = TextMotions.lineStart(text, i);
    final end = TextMotions.lineEnd(text, i);

    // Insertion point: after leading whitespace on this line.
    var indent = start;
    while (indent < end &&
        (text.codeUnitAt(indent) == 0x20 || text.codeUnitAt(indent) == 0x09)) {
      indent++;
    }

    final body = text.substring(indent, end);
    if (body.startsWith(lineComment)) {
      // Uncomment: drop the token plus at most one following space.
      var removeLen = lineComment.length;
      if (body.length > removeLen && body.codeUnitAt(removeLen) == 0x20) {
        removeLen++;
      }
      final next =
          text.substring(0, indent) + text.substring(indent + removeLen);
      final int newCaret;
      if (i >= indent + removeLen) {
        newCaret = i - removeLen;
      } else if (i > indent) {
        newCaret = indent;
      } else {
        newCaret = i;
      }
      return (text: next, caret: newCaret);
    }

    final prefix = '$lineComment ';
    final next = text.substring(0, indent) + prefix + text.substring(indent);
    return (text: next, caret: i >= indent ? i + prefix.length : i);
  }

  // ----------------------------------------------------------------- zapping

  /// M-z — kill from the caret through the next occurrence of [ch]
  /// (inclusive), discarding the killed text.
  static ({String text, int caret}) zapToChar(
      String text, int caret, String ch) {
    final r = zapToCharKill(text, caret, ch);
    return (text: r.text, caret: r.caret);
  }

  /// M-z, kill-ring flavour — as [zapToChar] but also returns the killed span
  /// so the host can push it onto the kill ring. With no occurrence at/after
  /// the caret the text is unchanged and `killed` is `''`.
  static ({String text, int caret, String killed}) zapToCharKill(
    String text,
    int caret,
    String ch,
  ) {
    final i = caret.clamp(0, text.length);
    if (ch.isEmpty) return (text: text, caret: i, killed: '');
    final hit = text.indexOf(ch, i);
    if (hit < 0) return (text: text, caret: i, killed: '');
    final end = hit + ch.length;
    return (
      text: text.substring(0, i) + text.substring(end),
      caret: i,
      killed: text.substring(i, end),
    );
  }

  // ------------------------------------------------------------ transposition

  /// M-t — swap the word before the caret with the word after it, leaving the
  /// caret after the second (now later) word. Unchanged when either word is
  /// missing.
  static ({String text, int caret}) transposeWords(String text, int caret) {
    final i = caret.clamp(0, text.length);
    final second = _wordAt(text, i);
    if (second == null) return (text: text, caret: i);
    final s2 = second[0], e2 = second[1];

    // The word before it: backwardWord from the second word's start lands on
    // the previous word's start (or 0 when there is none).
    final s1 = TextMotions.backwardWord(text, s2);
    final e1 = TextMotions.forwardWord(text, s1);
    if (s1 >= s2 || e1 > s2)
      return (text: text, caret: i); // No preceding word.

    final w1 = text.substring(s1, e1);
    final middle = text.substring(e1, s2);
    final w2 = text.substring(s2, e2);
    final next = text.substring(0, s1) + w2 + middle + w1 + text.substring(e2);
    // Lengths are preserved, so the far edge of the pair is still at e2.
    return (text: next, caret: e2);
  }

  /// C-x C-t — swap the caret's line with the one above it. The caret rides
  /// with its own line (same column, one line earlier). Unchanged on the
  /// first line.
  static ({String text, int caret}) transposeLines(String text, int caret) {
    final i = caret.clamp(0, text.length);
    final line = _lineOf(text, i);
    if (line == 0) return (text: text, caret: i);
    final column = i - TextMotions.lineStart(text, i);

    final lines = text.split('\n');
    final moved = lines[line];
    lines[line] = lines[line - 1];
    lines[line - 1] = moved;
    final next = lines.join('\n');
    return (text: next, caret: _offsetAt(next, line - 1, column));
  }

  // ---------------------------------------------------------------- gotoLine

  /// M-g g — move the caret to the start of 1-indexed [line], clamped into
  /// range. The text is never modified.
  static ({String text, int caret}) gotoLine(String text, int line) {
    final count = '\n'.allMatches(text).length + 1;
    final target = line.clamp(1, count);
    return (text: text, caret: _startOfLine(text, target - 1));
  }

  // -------------------------------------------------------------- rectangles

  /// C-x r k — kill the rectangle spanned by [start] and [end]: the column
  /// range between the two offsets, on every line between them.
  ///
  /// Returns the removed column strings, one per line, top to bottom. Lines
  /// too short to reach the rectangle contribute whatever they have (possibly
  /// `''`) — no space padding. The caret lands on the rectangle's upper-left
  /// corner in the new text.
  static ({String text, int caret, List<String> rect}) killRectangle(
    String text,
    int start,
    int end,
  ) {
    final a = start.clamp(0, text.length);
    final b = end.clamp(0, text.length);
    final lineA = _lineOf(text, a);
    final lineB = _lineOf(text, b);
    final colA = a - TextMotions.lineStart(text, a);
    final colB = b - TextMotions.lineStart(text, b);

    final top = lineA <= lineB ? lineA : lineB;
    final bottom = lineA <= lineB ? lineB : lineA;
    final left = colA <= colB ? colA : colB;
    final right = colA <= colB ? colB : colA;

    final lines = text.split('\n');
    final rect = <String>[];
    for (var l = top; l <= bottom && l < lines.length; l++) {
      final s = lines[l];
      final lo = left.clamp(0, s.length);
      final hi = right.clamp(0, s.length);
      rect.add(s.substring(lo, hi));
      lines[l] = s.substring(0, lo) + s.substring(hi);
    }
    final next = lines.join('\n');
    return (text: next, caret: _offsetAt(next, top, left), rect: rect);
  }

  /// C-x r y — insert [rect]'s strings as a rectangle, the first at the
  /// caret's column and the rest on successive lines at that same column.
  ///
  /// Lines shorter than the caret's column are padded with spaces; lines past
  /// the end of the text are created. As in Emacs, the caret ends at the
  /// rectangle's lower-right corner. An empty [rect] changes nothing.
  static ({String text, int caret}) yankRectangle(
    String text,
    int caret,
    List<String> rect,
  ) {
    final i = caret.clamp(0, text.length);
    if (rect.isEmpty) return (text: text, caret: i);
    final line = _lineOf(text, i);
    final column = i - TextMotions.lineStart(text, i);

    final lines = text.split('\n');
    for (var n = 0; n < rect.length; n++) {
      final l = line + n;
      while (l >= lines.length) {
        lines.add('');
      }
      var s = lines[l];
      if (s.length < column) s = s.padRight(column);
      lines[l] = s.substring(0, column) + rect[n] + s.substring(column);
    }
    final next = lines.join('\n');
    return (
      text: next,
      caret: _offsetAt(next, line + rect.length - 1, column + rect.last.length),
    );
  }
}
