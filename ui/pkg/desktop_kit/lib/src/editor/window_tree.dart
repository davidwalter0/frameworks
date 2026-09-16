// Pure split-tree model for Emacs-style windows (C-x 2 / 3 / 0 / 1 / o).
// See docs/design/multi-window-buffer-controller.org (Decision 3) for the
// full rationale. Still deliberately FLUTTER-free, so split/close/cycle can be
// table-tested without a widget pump; the Org Editor page renders
// [WindowTree.leaves] into nested Row/Column widgets, each leaf bound to the
// same shared `EmacsBufferController`.
//
// A leaf holds the [Buffer] OBJECT it displays (Emacs `window-buffer`), not a
// widget/view identity and — since the phase that introduced this import — not
// a NAME either. The single import of `emacs_buffer.dart` relaxes the older
// "nothing beyond dart:core" rule but preserves the property that rule existed
// to protect: `emacs_buffer.dart` is itself transitively Flutter-free, so this
// file is still headlessly testable with a plain `Buffer('name', text, caret)`.
//
// Why the object and not the name: a name is a key into the model's buffer
// index, and keys expire. `renameBuffer` re-keys that index, so every window
// holding the old name dangled — repaired, if at all, by a read-time fixup
// that could not tell a renamed buffer from a killed one. Holding the object
// makes a rename a non-event and makes "is this window's buffer still alive?"
// an identity question ([EmacsBuffer.isLive]) rather than a name lookup that
// answers yes for an unrelated buffer that merely reused the name.
library;

import 'emacs_buffer.dart' show Buffer;

/// A node in the split tree: either a [WindowLeaf] (one editor pane) or a
/// [WindowSplit] (a row/column of child nodes).
sealed class WindowNode {
  const WindowNode();
}

/// One editor pane, holding the [Buffer] it shows (Emacs `window-buffer`).
/// `id` is stable for the lifetime of the pane (used to track focus and to
/// address ops); v2 will also carry the pane's own `PointRef` (see the design
/// doc, Decision 2) — v1 intentionally does not, since point is still shared
/// via the buffer.
final class WindowLeaf extends WindowNode {
  WindowLeaf(this.id, this.buffer);

  final int id;

  /// The buffer this window displays — the OBJECT, so it survives a rename and
  /// so [EmacsBuffer.isLive] can tell "still open" from "killed, and the name
  /// reused by something else".
  ///
  /// Mutable: repointing a window at another buffer (`C-x b` in this window,
  /// or a host repairing a window left on a killed buffer) is an assignment
  /// here. The tree's structural ops are still immutable rewrites.
  Buffer buffer;

  /// The displayed buffer's name — DERIVED, never stored.
  ///
  /// This used to be the field, and storing it is what let a window's idea of
  /// which buffer it showed drift from the model's. Reading it through the
  /// object means it cannot be stale by construction: a rename updates
  /// [Buffer.name] on the very object this leaf points at.
  String get bufferName => buffer.name;

  @override
  String toString() => 'WindowLeaf($id, $bufferName)';
}

/// Which way a [WindowSplit]'s children lay out. `row` = side-by-side
/// (`C-x 3`, split-window-right); `column` = stacked (`C-x 2`,
/// split-window-below).
enum SplitAxis { row, column }

/// A row or column of >= 2 child nodes (leaves and/or nested splits).
final class WindowSplit extends WindowNode {
  WindowSplit(this.axis, this.children) : assert(children.length >= 2);

  final SplitAxis axis;
  final List<WindowNode> children;

  @override
  String toString() => 'WindowSplit($axis, $children)';
}

/// The split tree for one page: a [root] node plus the id of the currently
/// *focused* leaf. Every operation is an immutable rewrite — it returns a
/// new [WindowTree] rather than mutating this one — so a page can hold it in
/// `State` and diff old/new for a focus/structure repaint.
class WindowTree {
  WindowTree(this.root, this.focusedId);

  /// A tree with a single window showing [buffer].
  factory WindowTree.single(Buffer buffer, {int id = 0}) =>
      WindowTree(WindowLeaf(id, buffer), id);

  final WindowNode root;
  final int focusedId;

  /// The currently focused leaf (Emacs's selected window), or null when
  /// [focusedId] names no leaf. Its [WindowLeaf.buffer] is the buffer this
  /// window points at — and, once a host wires
  /// [EmacsBuffer.selectBuffer] / [EmacsBuffer.onSelectionChanged], the buffer
  /// the model has selected.
  WindowLeaf? get focusedLeaf => _findLeaf(root, focusedId);

  /// `C-x 2` (split-window-below): replaces the focused leaf with a
  /// `column` split of [original, clone] (clone inherits the focused
  /// leaf's BUFFER, so both windows show the same buffer as in Emacs —
  /// cloning a stale buffer NAME here is what used to make a split taken
  /// after a `C-x b` show two DIFFERENT buffers).
  /// If the focused leaf is already a direct child of
  /// a `column` split, the clone is inserted as a new sibling immediately
  /// after it instead of nesting a redundant single-axis split
  /// ("flatten same-axis", per the design doc). Focus stays on the
  /// original leaf's id (matches Emacs: the window you split from stays
  /// selected). No-op if [focusedId] does not name a leaf in this tree.
  WindowTree splitBelow() => _split(SplitAxis.column);

  /// `C-x 3` (split-window-right): as [splitBelow] but a `row` split.
  WindowTree splitRight() => _split(SplitAxis.row);

  /// `C-x 0` (delete-window): removes the focused leaf and collapses any
  /// parent split that drops to a single remaining child (including the
  /// root itself, so closing the last-but-one window returns a
  /// single-leaf tree, not a one-child split). No-op if this is the only
  /// window, or if [focusedId] does not name a leaf in this tree. Focus
  /// moves to the first remaining leaf in traversal order.
  WindowTree closeCurrent() {
    if (root is WindowLeaf) return this;
    if (!leaves().any((WindowLeaf l) => l.id == focusedId)) return this;
    final WindowNode newRoot = _removeLeaf(root, focusedId);
    final List<WindowLeaf> remaining = _collectLeaves(newRoot);
    final int newFocus = remaining.isNotEmpty ? remaining.first.id : focusedId;
    return WindowTree(newRoot, newFocus);
  }

  /// `C-x 1` (delete-other-windows): replaces the root with just the
  /// focused leaf. No-op if the focused leaf is already the only window,
  /// or if [focusedId] does not name a leaf in this tree.
  WindowTree only() {
    final WindowLeaf? focused = _findLeaf(root, focusedId);
    if (focused == null) return this;
    if (root is WindowLeaf) return this; // already the only window
    return WindowTree(WindowLeaf(focused.id, focused.buffer), focused.id);
  }

  /// `C-x o` (other-window): advances focus to the next leaf in traversal
  /// order, wrapping around after the last leaf. No-op with 0 or 1 leaves,
  /// or if [focusedId] does not name a leaf in this tree.
  WindowTree cycleFocus() {
    final List<WindowLeaf> ls = leaves();
    if (ls.length <= 1) return this;
    final int i = ls.indexWhere((WindowLeaf l) => l.id == focusedId);
    if (i == -1) return this;
    return WindowTree(root, ls[(i + 1) % ls.length].id);
  }

  /// Every leaf in the tree, pre-order (top-to-bottom / left-to-right at
  /// each split) — the deterministic order both rendering and
  /// [cycleFocus] use.
  List<WindowLeaf> leaves() => _collectLeaves(root);

  // -- internals ----------------------------------------------------------

  WindowTree _split(SplitAxis axis) {
    final WindowLeaf? focused = _findLeaf(root, focusedId);
    if (focused == null) return this;
    final int newId = _maxId(root) + 1;
    final WindowNode newRoot = _insertSplit(root, focusedId, axis, newId);
    return WindowTree(newRoot, focusedId);
  }

  static WindowNode _insertSplit(
    WindowNode node,
    int id,
    SplitAxis axis,
    int newId,
  ) {
    if (node is WindowLeaf) {
      if (node.id != id) return node;
      return WindowSplit(axis, <WindowNode>[
        WindowLeaf(node.id, node.buffer),
        WindowLeaf(newId, node.buffer),
      ]);
    }
    final WindowSplit split = node as WindowSplit;
    if (split.axis == axis) {
      final int idx = split.children.indexWhere(
        (WindowNode c) => c is WindowLeaf && c.id == id,
      );
      if (idx != -1) {
        final WindowLeaf target = split.children[idx] as WindowLeaf;
        final List<WindowNode> newChildren =
            List<WindowNode>.of(split.children);
        newChildren.insert(idx + 1, WindowLeaf(newId, target.buffer));
        return WindowSplit(split.axis, newChildren);
      }
    }
    return WindowSplit(split.axis, <WindowNode>[
      for (final WindowNode c in split.children)
        _insertSplit(c, id, axis, newId),
    ]);
  }

  /// Rebuilds [node] with the leaf whose id == [id] dropped; a split whose
  /// children list drops to length 1 collapses into that remaining child.
  static WindowNode _removeLeaf(WindowNode node, int id) {
    if (node is WindowLeaf) {
      // Only called with node as (an ancestor of) a match; a bare leaf
      // reaching here that isn't the target is returned unchanged.
      return node;
    }
    final WindowSplit split = node as WindowSplit;
    final List<WindowNode> newChildren = <WindowNode>[
      for (final WindowNode c in split.children)
        if (!(c is WindowLeaf && c.id == id)) _removeLeaf(c, id),
    ];
    if (newChildren.length == 1) return newChildren.first;
    return WindowSplit(split.axis, newChildren);
  }

  static List<WindowLeaf> _collectLeaves(WindowNode node) {
    if (node is WindowLeaf) return <WindowLeaf>[node];
    final WindowSplit split = node as WindowSplit;
    return <WindowLeaf>[
      for (final WindowNode c in split.children) ..._collectLeaves(c),
    ];
  }

  static WindowLeaf? _findLeaf(WindowNode node, int id) {
    if (node is WindowLeaf) return node.id == id ? node : null;
    final WindowSplit split = node as WindowSplit;
    for (final WindowNode c in split.children) {
      final WindowLeaf? found = _findLeaf(c, id);
      if (found != null) return found;
    }
    return null;
  }

  static int _maxId(WindowNode node) {
    if (node is WindowLeaf) return node.id;
    final WindowSplit split = node as WindowSplit;
    int m = 0;
    for (final WindowNode c in split.children) {
      final int cm = _maxId(c);
      if (cm > m) m = cm;
    }
    return m;
  }
}
