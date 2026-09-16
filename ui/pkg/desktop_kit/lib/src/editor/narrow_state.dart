// A pure model of Emacs "narrowing" (`narrow-to-region` / `widen`): the
// editor keeps rendering the full buffer, but everything outside the narrowed
// range is hidden, as if the buffer temporarily ended at its edges. No
// Flutter dependency; the widget layer is responsible for turning
// [hiddenLines] into whatever it hides lines with elsewhere (folding, etc).
library;

/// Narrowing state for one buffer: an inclusive `[startLine, endLine]` range
/// of 0-based line indices, or "not narrowed" when [active] is false.
class NarrowState {
  int? _startLine;
  int? _endLine;

  /// The narrowed range's first visible line, or null when not narrowed.
  int? get startLine => _startLine;

  /// The narrowed range's last visible line, or null when not narrowed.
  int? get endLine => _endLine;

  /// Whether the buffer is currently narrowed.
  bool get active => _startLine != null && _endLine != null;

  /// Narrows the buffer to the inclusive line range `[start, end]`
  /// (`narrow-to-region`). [start] and [end] are normalized so the smaller
  /// value is always [startLine], matching Emacs's region-order tolerance.
  void narrowTo(int start, int end) {
    _startLine = start <= end ? start : end;
    _endLine = start <= end ? end : start;
  }

  /// Clears narrowing, restoring the full buffer (`widen`).
  void widen() {
    _startLine = null;
    _endLine = null;
  }

  /// The set of 0-based line indices in a buffer of [totalLines] lines that
  /// fall outside the narrowed range and should therefore be hidden. Empty
  /// when not [active]. Every line index in `[0, totalLines)` outside
  /// `[startLine, endLine]` is included — including edges (line 0 when
  /// [startLine] > 0, and `totalLines - 1` when [endLine] < totalLines - 1).
  Set<int> hiddenLines(int totalLines) {
    if (!active) return const <int>{};
    final int s = _startLine!;
    final int e = _endLine!;
    final Set<int> out = <int>{};
    for (int i = 0; i < totalLines; i++) {
      if (i < s || i > e) out.add(i);
    }
    return out;
  }
}
