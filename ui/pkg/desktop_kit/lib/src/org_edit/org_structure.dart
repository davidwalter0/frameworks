// Pure org structure-editing operations over (text, caret).
//
// Each function below takes the buffer text and a caret (buffer offset) and
// returns a new (text, caret) pair. No Flutter, no editor coupling — the
// editor widget calls these and re-paints/re-folds afterward. Heading
// detection mirrors org_fold.dart's OrgFold: a heading is one-or-more `*`
// followed by a space.
library;

/// A pure (text, caret) result — every op in this file returns one of these.
typedef OrgEdit = ({String text, int caret});

/// The star-count of a heading line (`** foo` -> 2), or 0 when [line] is not
/// a heading. Mirrors `OrgFold._headingLevel` in org_fold.dart (private
/// there, so replicated here rather than shared).
int _headingLevel(String line) {
  int stars = 0;
  while (stars < line.length && line.codeUnitAt(stars) == 0x2A) {
    stars++;
  }
  if (stars == 0) return 0;
  if (stars < line.length && line[stars] == ' ') return stars;
  return 0;
}

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

/// A heading line and its outline level, with its buffer line index.
typedef _Heading = ({int line, int level});

List<_Heading> _headings(List<String> lines) {
  final List<_Heading> out = <_Heading>[];
  for (int i = 0; i < lines.length; i++) {
    final int level = _headingLevel(lines[i]);
    if (level > 0) out.add((line: i, level: level));
  }
  return out;
}

/// The exclusive end line of heading `hs[i]`'s subtree: the next heading at
/// the same or a shallower level, or the end of the buffer. Replicated from
/// `OrgFold._subtreeEnd` in org_fold.dart (private there, so replicated here
/// rather than shared).
int _subtreeEnd(List<_Heading> hs, int i, int lineCount) {
  final int level = hs[i].level;
  for (int j = i + 1; j < hs.length; j++) {
    if (hs[j].level <= level) return hs[j].line;
  }
  return lineCount;
}

/// The index (into [hs]) of the heading at-or-above buffer line [li]
/// (org-back-to-heading semantics): the nearest heading whose subtree [li]
/// belongs to. Null when there is no such heading.
int? _enclosingHeadingIndex(List<_Heading> hs, int li) {
  int? found;
  for (int i = 0; i < hs.length; i++) {
    if (hs[i].line <= li) {
      found = i;
    } else {
      break;
    }
  }
  return found;
}

/// The index (into [hs]) of the previous SIBLING of `hs[hi]` — the nearest
/// earlier heading at the same level, provided nothing shallower sits
/// between them. Null when `hs[hi]` is the first child of its parent (or
/// the first top-level heading).
int? _previousSiblingIndex(List<_Heading> hs, int hi) {
  final int level = hs[hi].level;
  for (int k = hi - 1; k >= 0; k--) {
    if (hs[k].level <= level) {
      return hs[k].level == level ? k : null;
    }
  }
  return null;
}

/// The index (into [hs]) of the next SIBLING of `hs[hi]` — the nearest later
/// heading at the same level, provided nothing shallower sits between them.
/// Null when `hs[hi]` is the last child of its parent (or the last
/// top-level heading).
int? _nextSiblingIndex(List<_Heading> hs, int hi) {
  final int level = hs[hi].level;
  for (int k = hi + 1; k < hs.length; k++) {
    if (hs[k].level <= level) {
      return hs[k].level == level ? k : null;
    }
  }
  return null;
}

/// Remap [offset] through a splice that replaces `text[a, b)` with a segment
/// of length [newLen]: offsets before `a` are unchanged, offsets after `b`
/// shift by the length delta, and offsets inside `[a, b)` clamp into the new
/// segment.
int _spliceOffset(int offset, int a, int b, int newLen) {
  if (offset < a) return offset;
  if (offset >= b) return offset + (newLen - (b - a));
  return a + (offset - a).clamp(0, newLen);
}

/// M-RET: insert a new empty heading immediately after the line containing
/// [caret], at the same level as the current heading — or, when [caret] is
/// on a non-heading line, at the level of the enclosing heading (level 1 if
/// there is none). The caret lands right after the new heading's
/// stars-and-space.
OrgEdit insertHeadingAfter(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  int level = _headingLevel(lines[li]);
  if (level == 0) {
    final List<_Heading> hs = _headings(lines);
    final int? hi = _enclosingHeadingIndex(hs, li);
    level = hi == null ? 1 : hs[hi].level;
  }
  final String newLine = '${'*' * level} ';
  // Insert right before the current line's terminating newline (or at the
  // buffer's end, when the current line has none) so the last-line case
  // needs no special-casing.
  final int endOffset = starts[li] + lines[li].length;
  final String newText =
      '${text.substring(0, endOffset)}\n$newLine${text.substring(endOffset)}';
  return (text: newText, caret: endOffset + 1 + newLine.length);
}

/// Change the caret's heading level by [delta] stars (clamped to 1..9). A
/// no-op when [caret]'s line is not a heading, or when the clamp keeps the
/// level unchanged.
OrgEdit _changeLevel(String text, int caret, int delta) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  final int level = _headingLevel(lines[li]);
  if (level == 0) return (text: text, caret: caret);
  final int newLevel = (level + delta).clamp(1, 9);
  if (newLevel == level) return (text: text, caret: caret);
  final int a = starts[li];
  final int b = a + level;
  final String newSegment = '*' * newLevel;
  final String newText = text.substring(0, a) + newSegment + text.substring(b);
  final int newCaret = _spliceOffset(caret, a, b, newSegment.length);
  return (text: newText, caret: newCaret);
}

/// Promote the caret's heading by one star (fewer stars = shallower level;
/// clamped at level 1). No-op off a heading line.
OrgEdit promoteHeading(String text, int caret) => _changeLevel(text, caret, -1);

/// Demote the caret's heading by one star (more stars = deeper level;
/// clamped at level 9). No-op off a heading line.
OrgEdit demoteHeading(String text, int caret) => _changeLevel(text, caret, 1);

/// Cycle the TODO state of the caret's heading (the nearest heading
/// at-or-above the caret's line): none -> TODO -> DONE -> none. The keyword
/// is inserted/removed immediately after the heading's stars-and-space. A
/// no-op when there is no enclosing heading.
OrgEdit todoCycle(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  final List<_Heading> hs = _headings(lines);
  final int? hi = _enclosingHeadingIndex(hs, li);
  if (hi == null) return (text: text, caret: caret);
  final int headingLine = hs[hi].line;
  final int level = hs[hi].level;
  final String line = lines[headingLine];
  final int afterPrefix = level + 1; // stars + space
  final String rest =
      afterPrefix <= line.length ? line.substring(afterPrefix) : '';
  String? currentKeyword;
  if (rest.startsWith('TODO ')) {
    currentKeyword = 'TODO';
  } else if (rest.startsWith('DONE ')) {
    currentKeyword = 'DONE';
  }
  final String? nextKeyword = currentKeyword == null
      ? 'TODO'
      : (currentKeyword == 'TODO' ? 'DONE' : null);

  final int a = starts[headingLine] + afterPrefix;
  final int oldKeywordLen = currentKeyword == null
      ? 0
      : currentKeyword.length + 1; // includes the trailing space
  final int b = a + oldKeywordLen;
  final String newSegment = nextKeyword == null ? '' : '$nextKeyword ';
  final String newText = text.substring(0, a) + newSegment + text.substring(b);
  final int newCaret = _spliceOffset(caret, a, b, newSegment.length);
  return (text: newText, caret: newCaret);
}

/// Swap the buffer regions covered by sibling subtrees `hs[iFirst]` (which
/// must appear earlier in the document than `hs[iSecond]`, with nothing
/// between their two regions) — `first-region ++ second-region` becomes
/// `second-region ++ first-region`, with [caret] remapped through the swap.
OrgEdit _swapAdjacentSubtrees(
  String text,
  List<int> starts,
  int lineCount,
  List<_Heading> hs,
  int iFirst,
  int iSecond,
  int caret,
) {
  final int startFirst = starts[hs[iFirst].line];
  final int boundary = starts[hs[iSecond].line];
  final int endSecondLine = _subtreeEnd(hs, iSecond, lineCount);
  final int endOffset =
      endSecondLine < starts.length ? starts[endSecondLine] : text.length;

  final String segFirst = text.substring(startFirst, boundary);
  final String segSecond = text.substring(boundary, endOffset);
  final String newText = text.substring(0, startFirst) +
      segSecond +
      segFirst +
      text.substring(endOffset);

  int newCaret;
  if (caret < startFirst) {
    newCaret = caret;
  } else if (caret < boundary) {
    newCaret = startFirst + segSecond.length + (caret - startFirst);
  } else if (caret < endOffset) {
    newCaret = startFirst + (caret - boundary);
  } else {
    newCaret = caret; // beyond the swapped region: total length unchanged
  }
  return (text: newText, caret: newCaret);
}

/// Swap the caret's heading subtree with its previous SIBLING subtree
/// (whole line ranges). No-op when there is no enclosing heading, or it has
/// no previous sibling.
OrgEdit moveSubtreeUp(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  final List<_Heading> hs = _headings(lines);
  final int? hi = _enclosingHeadingIndex(hs, li);
  if (hi == null) return (text: text, caret: caret);
  final int? pi = _previousSiblingIndex(hs, hi);
  if (pi == null) return (text: text, caret: caret);
  return _swapAdjacentSubtrees(text, starts, lines.length, hs, pi, hi, caret);
}

/// Swap the caret's heading subtree with its next SIBLING subtree (whole
/// line ranges). No-op when there is no enclosing heading, or it has no
/// next sibling.
OrgEdit moveSubtreeDown(String text, int caret) {
  final List<String> lines = text.split('\n');
  final List<int> starts = _lineStarts(text);
  final int li = _lineAt(starts, caret);
  final List<_Heading> hs = _headings(lines);
  final int? hi = _enclosingHeadingIndex(hs, li);
  if (hi == null) return (text: text, caret: caret);
  final int? ni = _nextSiblingIndex(hs, hi);
  if (ni == null) return (text: text, caret: caret);
  return _swapAdjacentSubtrees(text, starts, lines.length, hs, hi, ni, caret);
}
