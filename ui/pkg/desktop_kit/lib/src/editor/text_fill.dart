// Pure fill-paragraph (M-q): reflow the blank-line-delimited paragraph
// containing the caret to a fixed fill column. No Flutter dependency, no
// editor coupling — mirrors the (text, caret) -> (text, caret) shape of
// `org_structure.dart`'s ops, and reuses its `OrgEdit` record type.
library;

import '../org_edit/org_structure.dart' show OrgEdit;

/// Reflows text paragraphs to a fill column, org-mode-aware on request.
class TextFill {
  TextFill._();

  /// Emacs' classic default `fill-column`.
  static const int fillColumn = 70;

  // ---- line helpers (replicated from `org_structure.dart`, private there)

  static List<int> _lineStarts(String text) {
    final List<int> starts = <int>[0];
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }

  static int _lineAt(List<int> starts, int caret) {
    for (int i = starts.length - 1; i >= 0; i--) {
      if (starts[i] <= caret) return i;
    }
    return 0;
  }

  /// Mirrors `org_structure.dart`'s `_headingLevel`: one-or-more `*` then a
  /// space. 0 when [line] is not a heading.
  static int _headingLevel(String line) {
    int stars = 0;
    while (stars < line.length && line.codeUnitAt(stars) == 0x2A) {
      stars++;
    }
    if (stars == 0) return 0;
    if (stars < line.length && line[stars] == ' ') return stars;
    return 0;
  }

  static bool _isBlank(String line) => line.trim().isEmpty;

  static bool _isTableLine(String line) => line.trimLeft().startsWith('|');

  static bool _isBlockDelim(String line) {
    final String t = line.trimLeft().toLowerCase();
    return t.startsWith('#+begin_') || t.startsWith('#+end_');
  }

  /// Lines fill-paragraph must never touch in org mode: headings, table
  /// rows, and `#+begin_*`/`#+end_*` block delimiters.
  static bool _isSkipLine(String line) =>
      _headingLevel(line) > 0 || _isTableLine(line) || _isBlockDelim(line);

  /// True when 0-based [line] sits strictly inside a `#+begin_*`/`#+end_*`
  /// pair (a source/example block body).
  static bool _insideBlock(List<String> lines, int line) {
    bool inside = false;
    for (int i = 0; i < line; i++) {
      final String t = lines[i].trimLeft().toLowerCase();
      if (t.startsWith('#+begin_')) {
        inside = true;
      } else if (t.startsWith('#+end_')) {
        inside = false;
      }
    }
    return inside;
  }

  /// True when [line] (0-based) is a boundary fill-paragraph must not cross:
  /// past either end of the buffer, blank, or — in org mode — a heading,
  /// table row, block delimiter, or a line inside a block body.
  static bool _isBoundary(List<String> lines, int line, bool orgMode) {
    if (line < 0 || line >= lines.length) return true;
    final String l = lines[line];
    if (_isBlank(l)) return true;
    if (orgMode && (_isSkipLine(l) || _insideBlock(lines, line))) return true;
    return false;
  }

  /// M-q — reflow the paragraph containing [caret] to [column] columns. A
  /// paragraph is a maximal run of non-blank lines, split greedily into
  /// lines of at most [column] characters (indentation preserved from the
  /// paragraph's first line); the caret is re-anchored to the same word it
  /// sat on/before beforehand.
  ///
  /// In org mode ([orgMode] true), fill-paragraph never touches heading
  /// lines, table rows, or `#+begin_*`/`#+end_*` block delimiters/bodies —
  /// when [caret] sits on/inside one of those (or on a blank line), the
  /// input is returned unchanged (identical text and caret) so the caller
  /// can report "nothing to fill".
  static OrgEdit fillParagraph(
    String text,
    int caret, {
    bool orgMode = false,
    int column = fillColumn,
  }) {
    final List<String> lines = text.split('\n');
    final List<int> starts = _lineStarts(text);
    final int li = _lineAt(starts, caret);
    if (li >= lines.length || _isBoundary(lines, li, orgMode)) {
      return (text: text, caret: caret);
    }

    int start = li;
    while (!_isBoundary(lines, start - 1, orgMode)) {
      start--;
    }
    int end = li; // inclusive
    while (!_isBoundary(lines, end + 1, orgMode)) {
      end++;
    }

    final String first = lines[start];
    final String indent =
        first.substring(0, first.length - first.trimLeft().length);

    // Flatten the paragraph's words with their absolute source offsets, so
    // the caret can be re-anchored to the same word after rewrapping.
    final List<String> words = <String>[];
    final List<int> wordStarts = <int>[];
    for (int i = start; i <= end; i++) {
      final int lineStart = starts[i];
      final String line = lines[i];
      int j = 0;
      while (j < line.length) {
        while (j < line.length && line[j] == ' ') {
          j++;
        }
        if (j >= line.length) break;
        final int ws = j;
        while (j < line.length && line[j] != ' ') {
          j++;
        }
        words.add(line.substring(ws, j));
        wordStarts.add(lineStart + ws);
      }
    }
    if (words.isEmpty) return (text: text, caret: caret);

    // The last word whose start offset is at-or-before the caret (or word 0
    // when the caret precedes every word — e.g. it sits in leading indent).
    int caretWordIndex = 0;
    for (int i = 0; i < wordStarts.length; i++) {
      if (wordStarts[i] <= caret) caretWordIndex = i;
    }

    // Greedy word-wrap at [column], with [indent] on every output line.
    final List<String> outLines = <String>[];
    final List<int> wordLineOfIndex = List<int>.filled(words.length, 0);
    final List<int> wordColOfIndex = List<int>.filled(words.length, 0);
    StringBuffer buf = StringBuffer(indent);
    int col = indent.length;
    bool lineHasWord = false;
    for (int i = 0; i < words.length; i++) {
      final String w = words[i];
      final int need = (lineHasWord ? 1 : 0) + w.length;
      if (lineHasWord && col + need > column) {
        outLines.add(buf.toString());
        buf = StringBuffer(indent);
        col = indent.length;
        lineHasWord = false;
      }
      if (lineHasWord) {
        buf.write(' ');
        col++;
      }
      wordLineOfIndex[i] = outLines.length;
      wordColOfIndex[i] = col;
      buf.write(w);
      col += w.length;
      lineHasWord = true;
    }
    outLines.add(buf.toString());

    final String newParagraph = outLines.join('\n');
    final int oldStartOffset = starts[start];
    final int oldEndOffset =
        end + 1 < starts.length ? starts[end + 1] - 1 : text.length;
    final String newText = text.substring(0, oldStartOffset) +
        newParagraph +
        text.substring(oldEndOffset);

    final List<int> newParaStarts = _lineStarts(newParagraph);
    final int newCaret = oldStartOffset +
        newParaStarts[wordLineOfIndex[caretWordIndex]] +
        wordColOfIndex[caretWordIndex];

    if (newText == text) return (text: text, caret: caret);
    return (text: newText, caret: newCaret.clamp(0, newText.length));
  }
}
