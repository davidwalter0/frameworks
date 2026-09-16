/// A region in a text buffer, as an inclusive-start / exclusive-end pair of
/// character offsets. Always normalized so [start] <= [end].
class Region {
  const Region(this.start, this.end);

  final int start;
  final int end;

  bool get isEmpty => start == end;
  int get length => end - start;

  @override
  bool operator ==(Object other) =>
      other is Region && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'Region($start, $end)';
}

/// Per-buffer Emacs mark state. The "point" is the caret position (owned by
/// the editor's TextEditingController); the "mark" is a remembered second
/// position. The region between them is what C-w / M-w operate on.
///
/// Pure and headlessly testable. The editor passes the live point into
/// [region]/[exchange] since the controller owns it.
class MarkState {
  MarkState();

  int? _mark;

  /// The mark offset, or null if no mark is set.
  int? get mark => _mark;
  bool get hasMark => _mark != null;

  /// Set the mark at [point] (C-SPC / set-mark-command). Activates the
  /// region anchored here.
  void setMark(int point) {
    _mark = point;
  }

  /// Clear the mark (C-g / deactivate-mark).
  void clear() {
    _mark = null;
  }

  /// The active region given the current [point], or null if no mark is set.
  /// Normalized so start <= end.
  Region? region(int point) {
    final m = _mark;
    if (m == null) return null;
    return Region(m < point ? m : point, m < point ? point : m);
  }

  /// Exchange point and mark (C-x C-x). Given the current [point], returns
  /// the position the caret should move to (the old mark) and stores the old
  /// point as the new mark. Returns null (no movement) if no mark is set.
  int? exchange(int point) {
    final m = _mark;
    if (m == null) return null;
    _mark = point;
    return m;
  }

  /// Adjust the stored mark after an edit at [editOffset] that changed the
  /// text length by [delta] (positive = insertion, negative = deletion).
  /// Keeps the mark anchored to the same logical position. Clamps to >= 0.
  void adjustForEdit(int editOffset, int delta) {
    final m = _mark;
    if (m == null) return;
    if (m > editOffset) {
      final next = m + delta;
      _mark = next < editOffset ? editOffset : next;
    }
  }
}
