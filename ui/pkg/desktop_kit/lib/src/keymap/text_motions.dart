/// Pure text-motion helpers for Emacs-style cursor movement and word/line
/// boundaries. All operate on `(text, offset)` and return a new offset or a
/// `[start, end)` span. No Flutter dependency.
class TextMotions {
  TextMotions._();

  static bool _isWordChar(int codeUnit) {
    // Letters, digits, underscore — close enough to Emacs `\w` for prose.
    final c = codeUnit;
    final isDigit = c >= 0x30 && c <= 0x39;
    final isUpper = c >= 0x41 && c <= 0x5A;
    final isLower = c >= 0x61 && c <= 0x7A;
    final isUnderscore = c == 0x5F;
    // Treat any non-ASCII (CJK, accented) as word characters too, so M-f
    // over Japanese text advances sensibly.
    final isHighUnicode = c > 0x7F;
    return isDigit || isUpper || isLower || isUnderscore || isHighUnicode;
  }

  /// forward-word (M-f): move past the next word. Skips non-word chars, then
  /// consumes word chars.
  static int forwardWord(String text, int offset) {
    var i = offset.clamp(0, text.length);
    while (i < text.length && !_isWordChar(text.codeUnitAt(i))) {
      i++;
    }
    while (i < text.length && _isWordChar(text.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// backward-word (M-b): move to the start of the previous word.
  static int backwardWord(String text, int offset) {
    var i = offset.clamp(0, text.length);
    while (i > 0 && !_isWordChar(text.codeUnitAt(i - 1))) {
      i--;
    }
    while (i > 0 && _isWordChar(text.codeUnitAt(i - 1))) {
      i--;
    }
    return i;
  }

  /// move-beginning-of-line (C-a): index of the first char on the current
  /// line (just after the preceding newline, or 0).
  static int lineStart(String text, int offset) {
    final i = offset.clamp(0, text.length);
    final nl = text.lastIndexOf('\n', i > 0 ? i - 1 : 0);
    if (i == 0) return 0;
    return nl < 0 ? 0 : nl + 1;
  }

  /// move-end-of-line (C-e): index just before the next newline, or the end.
  static int lineEnd(String text, int offset) {
    final i = offset.clamp(0, text.length);
    final nl = text.indexOf('\n', i);
    return nl < 0 ? text.length : nl;
  }

  /// forward-char (C-f).
  static int forwardChar(String text, int offset) =>
      (offset + 1).clamp(0, text.length);

  /// backward-char (C-b).
  static int backwardChar(String text, int offset) =>
      (offset - 1).clamp(0, text.length);

  /// next-line (C-n): same visual column on the following line. Falls back
  /// to end-of-text when there is no following line.
  static int nextLine(String text, int offset) {
    final col = offset - lineStart(text, offset);
    final eol = lineEnd(text, offset);
    if (eol >= text.length) return text.length; // last line.
    final nextStart = eol + 1;
    final nextEol = lineEnd(text, nextStart);
    final target = nextStart + col;
    return target > nextEol ? nextEol : target;
  }

  /// previous-line (C-p): same visual column on the previous line.
  static int previousLine(String text, int offset) {
    final start = lineStart(text, offset);
    final col = offset - start;
    if (start == 0) return 0; // first line.
    final prevEol = start - 1; // the newline ending the prior line.
    final prevStart = lineStart(text, prevEol);
    final target = prevStart + col;
    return target > prevEol ? prevEol : target;
  }

  /// Span deleted by C-k (kill-line): from [offset] to end-of-line, or — if
  /// already at end-of-line — the single newline (so C-k joins lines).
  /// Returns `[start, end)`.
  static List<int> killLineSpan(String text, int offset) {
    final i = offset.clamp(0, text.length);
    final eol = lineEnd(text, i);
    if (eol > i) return [i, eol];
    if (eol < text.length) return [i, eol + 1]; // delete the newline.
    return [i, i]; // nothing to kill.
  }

  /// Span deleted by C-d (delete-char): the single char after [offset].
  static List<int> deleteCharSpan(String text, int offset) {
    final i = offset.clamp(0, text.length);
    if (i >= text.length) return [i, i];
    return [i, i + 1];
  }

  /// Span deleted by M-d (kill-word / delete-word-forward): from [offset] to
  /// the end of the next word. Mirrors [forwardWord].
  static List<int> deleteWordForwardSpan(String text, int offset) {
    final start = offset.clamp(0, text.length);
    final end = forwardWord(text, start);
    return [start, end];
  }

  /// Span deleted by M-Backspace (backward-kill-word): from the start of the
  /// previous word to [offset]. Mirrors [backwardWord].
  static List<int> deleteWordBackwardSpan(String text, int offset) {
    final end = offset.clamp(0, text.length);
    final start = backwardWord(text, end);
    return [start, end];
  }
}
