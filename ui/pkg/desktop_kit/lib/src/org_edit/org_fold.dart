// A pure org-outline FOLD model over a text buffer's lines.
//
// Headings (`*`-prefixed lines) define a tree; folding a heading hides its
// subtree — every line down to (but not including) the next heading at the same
// or a shallower level. This computes which buffer lines are hidden and the
// org-cycle / global-cycle transitions, with NO Flutter and NO editor coupling:
// the editor widget owns an [OrgFold], asks it what to hide when it paints, and
// calls [reconcile] after edits. Fold state is keyed by line index — fragile
// under edits above a fold (real org uses markers); [reconcile] drops folds that
// are no longer on a heading, which is enough for a demo.
library;

/// A heading line and its outline level.
typedef OrgHeading = ({int line, int level});

/// A `#+begin_<kind> ... #+end_<kind>` block range (inclusive), keyed by its
/// begin line. Kinds are matched case-insensitively and treated generically —
/// src/quote/example/literal/verse/export/etc. all fold the same way. An
/// unterminated begin (no matching `#+end_`) extends to the buffer's last
/// line, so it always folds/hides *something* rather than throwing.
typedef OrgBlock = ({int line, int endLine, String kind});

/// The fold state for one org buffer. Mutable; the editor toggles it.
///
/// Fold state is a single `Set<int>` of "node begin lines" shared by both
/// headings and blocks — a heading line and a block's `#+begin_` line never
/// coincide, so the same set safely keys either kind of foldable node.
class OrgFold {
  /// Begin-line indices of currently-folded nodes (heading or block).
  final Set<int> _folded = <int>{};

  static final RegExp _beginRe = RegExp(
    r'^\s*#\+begin_(\S+)',
    caseSensitive: false,
  );
  static final RegExp _endRe = RegExp(
    r'^\s*#\+end_(\S+)',
    caseSensitive: false,
  );

  /// The heading lines in [text] with their 1-based levels, in document order.
  static List<OrgHeading> headings(String text) {
    final List<OrgHeading> out = <OrgHeading>[];
    final List<String> lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final int level = _headingLevel(lines[i]);
      if (level > 0) out.add((line: i, level: level));
    }
    return out;
  }

  /// The `#+begin_*`/`#+end_*` block ranges in [text], in document order.
  /// Nesting is resolved by matching each `#+end_<kind>` against the nearest
  /// still-open `#+begin_<kind>` (falling back to the innermost open block on
  /// a kind mismatch); any begin left unclosed at buffer end extends to the
  /// last line.
  static List<OrgBlock> blocks(String text) {
    final List<String> lines = text.split('\n');
    final List<({int line, String kind})> stack = <({int line, String kind})>[];
    final List<OrgBlock> out = <OrgBlock>[];
    for (int i = 0; i < lines.length; i++) {
      final RegExpMatch? mb = _beginRe.firstMatch(lines[i]);
      if (mb != null) {
        stack.add((line: i, kind: mb.group(1)!.toLowerCase()));
        continue;
      }
      final RegExpMatch? me = _endRe.firstMatch(lines[i]);
      if (me != null && stack.isNotEmpty) {
        final String kind = me.group(1)!.toLowerCase();
        int idx = stack.lastIndexWhere((e) => e.kind == kind);
        if (idx == -1) idx = stack.length - 1;
        final ({int line, String kind}) start = stack.removeAt(idx);
        out.add((line: start.line, endLine: i, kind: start.kind));
      }
    }
    for (final ({int line, String kind}) start in stack) {
      out.add((line: start.line, endLine: lines.length - 1, kind: start.kind));
    }
    out.sort((a, b) => a.line.compareTo(b.line));
    return out;
  }

  /// The star-count of a heading line (`** foo` → 2), or 0 when [line] is not a
  /// heading. A heading is one-or-more `*` followed by a space.
  static int _headingLevel(String line) {
    int stars = 0;
    while (stars < line.length && line.codeUnitAt(stars) == 0x2A) {
      stars++;
    }
    if (stars == 0) return 0;
    if (stars < line.length && line[stars] == ' ') return stars;
    return 0;
  }

  /// Whether the heading at [line] is folded.
  bool isFolded(int line) => _folded.contains(line);

  /// Whether anything is folded.
  bool get anyFolded => _folded.isNotEmpty;

  /// The buffer line indices hidden by the current folds in [text]. A line
  /// inside a folded ancestor is hidden regardless of its own fold state.
  Set<int> hiddenLines(String text) {
    final List<OrgHeading> hs = headings(text);
    final int lineCount = text.split('\n').length;
    final Set<int> hidden = <int>{};
    for (int i = 0; i < hs.length; i++) {
      final OrgHeading h = hs[i];
      if (hidden.contains(h.line)) continue; // an ancestor already hid it
      if (!_folded.contains(h.line)) continue;
      final int end = _subtreeEnd(hs, i, lineCount);
      for (int l = h.line + 1; l < end; l++) {
        hidden.add(l);
      }
    }
    // A folded block hides its body + end line, keeping the begin line (with
    // its fold ellipsis) visible — unless a folded ancestor heading already
    // hid the whole thing, in which case this is a no-op (Set union).
    for (final OrgBlock b in blocks(text)) {
      if (hidden.contains(b.line)) continue;
      if (!_folded.contains(b.line)) continue;
      for (int l = b.line + 1; l <= b.endLine; l++) {
        hidden.add(l);
      }
    }
    return hidden;
  }

  /// The exclusive end line of heading [hs]\[i]'s subtree: the next heading at
  /// the same or a shallower level, or the end of the buffer.
  static int _subtreeEnd(List<OrgHeading> hs, int i, int lineCount) {
    final int level = hs[i].level;
    for (int j = i + 1; j < hs.length; j++) {
      if (hs[j].level <= level) return hs[j].line;
    }
    return lineCount;
  }

  /// org-cycle at [line]: toggle the fold of the nearest enclosing foldable
  /// node — a block wins over an enclosing heading (nearest-node-wins) when
  /// [line] sits on the block's begin/end line or inside its body; otherwise
  /// the nearest heading at or above [line] (the heading whose subtree [line]
  /// is in). Returns the toggled node's begin line, or null when neither a
  /// block nor a heading covers [line].
  int? cycleAt(String text, int line) {
    OrgBlock? blockHit;
    for (final OrgBlock b in blocks(text)) {
      if (line >= b.line && line <= b.endLine) {
        if (blockHit == null || b.line > blockHit.line) blockHit = b;
      }
    }
    final int? target = blockHit?.line ?? _headingAtOrAbove(text, line);
    if (target == null) return null;
    if (_folded.contains(target)) {
      _folded.remove(target);
    } else {
      _folded.add(target);
    }
    return target;
  }

  /// The nearest heading at or above [line], or null above the first heading.
  static int? _headingAtOrAbove(String text, int line) {
    int? target;
    for (final OrgHeading h in headings(text)) {
      if (h.line <= line) {
        target = h.line;
      } else {
        break;
      }
    }
    return target;
  }

  /// org-global-cycle (S-TAB), 2-state: if anything is folded, show all; else
  /// fold every heading (overview — only top-level headings stay visible, since
  /// a folded top heading hides its nested headings).
  void globalCycle(String text) {
    if (_folded.isNotEmpty) {
      _folded.clear();
      return;
    }
    foldAll(text);
  }

  /// Fold every heading in [text].
  void foldAll(String text) {
    _folded
      ..clear()
      ..addAll(<int>[for (final OrgHeading h in headings(text)) h.line]);
  }

  /// Unfold everything.
  void unfoldAll() => _folded.clear();

  /// Unfold the single node folded at [line] (no-op when it isn't folded) —
  /// the primitive the speed-key accordion composes with [foldAll].
  void unfold(int line) => _folded.remove(line);

  /// Drop folds that no longer land on a heading (after an edit changed the
  /// text). Keeps the model from hiding arbitrary lines when headings move or
  /// disappear.
  void reconcile(String text) {
    final Set<int> nodeLines = <int>{
      for (final OrgHeading h in headings(text)) h.line,
      for (final OrgBlock b in blocks(text)) b.line,
    };
    _folded.retainWhere(nodeLines.contains);
  }
}

/// The view of a buffer with folded lines removed — the bridge between the model
/// (buffer coordinates) and a painted editor (display coordinates). Pure and
/// fully testable so the offset maths — where folding bugs hide — is verified
/// without a widget.
class FoldedView {
  const FoldedView({
    required this.text,
    required this.caret,
    required this.srcForDisplay,
    required this.dispForBuffer,
    required this.bufferLineNumbers,
  });

  /// The display text: the buffer with hidden lines dropped and a fold ellipsis
  /// appended to each folded heading.
  final String text;

  /// The caret in display coordinates (a caret inside a hidden region lands on
  /// its heading's fold marker).
  final int caret;

  /// `srcForDisplay[d]` = the buffer offset of display char `d` (length
  /// `text.length + 1`; ellipsis chars map to their heading's end-of-line).
  final List<int> srcForDisplay;

  /// `dispForBuffer[b]` = the display offset of buffer offset `b` (length
  /// `bufferText.length + 1`; a hidden offset maps to its fold marker).
  final List<int> dispForBuffer;

  /// The 1-based BUFFER line number of each visible display line — for the
  /// gutter, so hidden lines leave gaps in the numbering.
  final List<int> bufferLineNumbers;

  /// Display offset -> buffer offset (for mouse hit-testing).
  int toBuffer(int displayOffset) =>
      srcForDisplay[displayOffset.clamp(0, srcForDisplay.length - 1)];

  /// Buffer offset -> display offset (for painting the caret).
  int toDisplay(int bufferOffset) =>
      dispForBuffer[bufferOffset.clamp(0, dispForBuffer.length - 1)];
}

/// The org-bullets rendering of a display [text]: on each heading line the
/// leading stars become (level-1) spaces + one bullet glyph — depth shown by
/// the bullet's position — UNLESS [caret] sits within that heading's star
/// prefix (you see the real asterisks exactly while typing them).
///
/// STRICTLY length-preserving: every substitution is one char for one char (a
/// bullet that is not a single UTF-16 unit falls back to `*`), so offset maps,
/// face spans and painter geometry computed against the input all remain
/// valid against the output. Pure; the editor calls it per frame.
String orgBulletsText(String text, int caret, List<String> bullets) {
  if (bullets.isEmpty) return text;
  final StringBuffer out = StringBuffer();
  int lineStart = 0;
  while (lineStart <= text.length) {
    int lineEnd = text.indexOf('\n', lineStart);
    final bool lastLine = lineEnd == -1;
    if (lastLine) lineEnd = text.length;
    final String line = text.substring(lineStart, lineEnd);
    int stars = 0;
    while (stars < line.length && line.codeUnitAt(stars) == 0x2A) {
      stars++;
    }
    final bool heading = stars > 0 && stars < line.length && line[stars] == ' ';
    // "Typing the stars": caret INSIDE the star run (column >= 1) or just
    // after the heading space — reveal until the first title character is
    // entered. Column 0 is deliberately EXCLUDED: speed keys and org
    // C-n/C-p land point at column 0 of a heading, and mere navigation must
    // never flip the glyph back to asterisks (the caret paints over the
    // glyph instead). You can only be *typing* stars from column 1 onward —
    // after the first `*` exists.
    final bool typing = caret > lineStart && caret <= lineStart + stars + 1;
    if (!heading || typing) {
      out.write(line);
    } else {
      // Glyph in the FAR-LEFT column, depth gap AFTER it — the bullet stays
      // put at column 0 at every level (a stable anchor for the eye and the
      // column-0 caret), while the title still indents by depth via the
      // substituted spaces. Length-preserving as ever.
      final String glyph = bullets[(stars - 1) % bullets.length];
      out.write(glyph.length == 1 ? glyph : '*');
      out.write(' ' * (stars - 1));
      out.write(line.substring(stars));
    }
    if (!lastLine) out.write('\n');
    lineStart = lineEnd + 1;
  }
  return out.toString();
}

/// Compute the [FoldedView] of [text] with [caret], given [fold]. With nothing
/// folded this is the identity (display == buffer), so the editor's unfolded
/// path is byte-identical. [extraHidden] is unioned into the fold's own
/// hidden-line set — the composition point for narrowing (see
/// `narrow_state.dart`'s [NarrowState.hiddenLines]): with nothing folded and
/// nothing narrowed both sets are empty, so the identity path is unchanged.
FoldedView foldView(
  String text,
  int caret,
  OrgFold fold, {
  String ellipsis = ' … ',
  Set<int> extraHidden = const <int>{},
}) {
  final List<String> lines = text.split('\n');
  final List<int> lineStart = <int>[];
  int p = 0;
  for (final String line in lines) {
    lineStart.add(p);
    p += line.length + 1; // +1 for the '\n'
  }
  final Set<int> hidden = extraHidden.isEmpty
      ? fold.hiddenLines(text)
      : (fold.hiddenLines(text)..addAll(extraHidden));
  // Folded NODES (headings or blocks) whose begin line stays visible and
  // needs the fold ellipsis appended.
  final Set<int> foldedNodes = <int>{
    for (final OrgHeading h in OrgFold.headings(text)) h.line,
    for (final OrgBlock b in OrgFold.blocks(text)) b.line,
  }..retainWhere(fold.isFolded);

  final StringBuffer sb = StringBuffer();
  final List<int> src = <int>[];
  final List<int> disp = List<int>.filled(text.length + 1, 0);
  final List<int> lineNums = <int>[];
  int dispPos = 0;
  bool first = true;

  for (int ln = 0; ln < lines.length; ln++) {
    final int bufStart = lineStart[ln];
    final String lineText = lines[ln];
    final int bufEnd =
        bufStart + lineText.length; // the trailing '\n' / text end
    if (hidden.contains(ln)) {
      for (int b = bufStart; b <= bufEnd && b <= text.length; b++) {
        disp[b] = dispPos; // a hidden offset collapses to the fold marker
      }
      continue;
    }
    if (!first) {
      sb.write('\n');
      src.add(bufStart - 1); // the newline that ends the previous visible line
      dispPos += 1;
    }
    first = false;
    lineNums.add(ln + 1);
    for (int c = 0; c < lineText.length; c++) {
      disp[bufStart + c] = dispPos;
      sb.write(lineText[c]);
      src.add(bufStart + c);
      dispPos += 1;
    }
    disp[bufEnd] = dispPos;
    if (foldedNodes.contains(ln)) {
      for (int k = 0; k < ellipsis.length; k++) {
        sb.write(ellipsis[k]);
        src.add(bufEnd);
        dispPos += 1;
      }
    }
  }
  src.add(text.length); // sentinel so src.length == displayText.length + 1

  return FoldedView(
    text: sb.toString(),
    caret: disp[caret.clamp(0, text.length)],
    srcForDisplay: src,
    dispForBuffer: disp,
    bufferLineNumbers: lineNums,
  );
}
