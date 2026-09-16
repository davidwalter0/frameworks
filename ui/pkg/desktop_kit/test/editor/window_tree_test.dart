import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// A distinct live [Buffer] named [name]. Bodies differ in LENGTH and LINE
/// COUNT per buffer name so a leaf that ends up pointing at the wrong buffer
/// is visible rather than coincidentally identical.
Buffer _buf(String name) =>
    Buffer(name, List<String>.filled(name.length, name).join('\n'), 0);

void main() {
  group('WindowTree — construction', () {
    test('single() builds a one-leaf tree focused on that leaf', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'));
      expect(tree.leaves(), hasLength(1));
      expect(tree.leaves().single.bufferName, '*scratch*');
      expect(tree.focusedId, tree.leaves().single.id);
    });
  });

  group('WindowTree — splitBelow / splitRight (C-x 2 / C-x 3)', () {
    test(
        'splitBelow wraps the focused leaf in a column split and keeps '
        'focus on the original', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'), id: 1);
      final WindowTree split = tree.splitBelow();

      expect(split.leaves(), hasLength(2));
      expect(split.focusedId, 1);
      expect(split.root, isA<WindowSplit>());
      expect((split.root as WindowSplit).axis, SplitAxis.column);
      final List<WindowLeaf> ls = split.leaves();
      expect(ls[0].bufferName, '*scratch*');
      expect(ls[1].bufferName, '*scratch*');
      expect(ls[0].id, isNot(ls[1].id));
    });

    test('splitRight wraps the focused leaf in a row split', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'), id: 1);
      final WindowTree split = tree.splitRight();

      expect((split.root as WindowSplit).axis, SplitAxis.row);
      expect(split.leaves(), hasLength(2));
    });

    test(
        'splitting a different buffer than the focused one clones the '
        "focused leaf's bufferName, not some other buffer's", () {
      final WindowTree tree = WindowTree.single(_buf('notes.org'), id: 5);
      final WindowTree split = tree.splitRight();
      expect(
        split.leaves().every((WindowLeaf l) => l.bufferName == 'notes.org'),
        isTrue,
      );
    });

    test(
        'splitting again on the same axis at a direct child flattens into '
        'a single split rather than nesting', () {
      final WindowTree once = WindowTree.single(_buf('*scratch*'), id: 1)
          .splitRight(); // row[1, 2], focus 1
      final WindowTree twice = once.splitRight(); // row[1, new, 2]? focus 1

      expect(twice.root, isA<WindowSplit>());
      final WindowSplit root = twice.root as WindowSplit;
      expect(root.axis, SplitAxis.row);
      expect(root.children, hasLength(3));
      expect(root.children.every((WindowNode n) => n is WindowLeaf), isTrue);
      expect(twice.leaves(), hasLength(3));
    });

    test('no-op when focusedId does not name a leaf in the tree', () {
      final WindowTree tree = WindowTree(WindowLeaf(1, _buf('*scratch*')), 99);
      expect(identical(tree.splitBelow(), tree), isTrue);
      expect(identical(tree.splitRight(), tree), isTrue);
    });
  });

  group('WindowTree — closeCurrent (C-x 0)', () {
    test('no-op on the only window', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'));
      expect(identical(tree.closeCurrent(), tree), isTrue);
    });

    test('closing the last-but-one window collapses back to a single leaf', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'), id: 1)
          .splitBelow(); // column[leaf(1), leaf(2)], focus 1
      final WindowTree closed = tree.closeCurrent();

      expect(closed.root, isA<WindowLeaf>());
      expect(closed.leaves(), hasLength(1));
      expect(closed.leaves().single.bufferName, '*scratch*');
      expect(closed.focusedId, closed.leaves().single.id);
    });

    test('closing one of three windows collapses only the emptied split', () {
      // row[ column[leaf(1), leaf(2)], leaf(3) ], focus on leaf(2).
      final WindowTree base = WindowTree.single(_buf('a'), id: 1)
          .splitBelow() // column[1, 2]
          .splitRight(); // row[column[1,2], 3], focus stays 1
      final WindowTree focusedOnTwo = WindowTree(base.root, 2);

      final WindowTree closed = focusedOnTwo.closeCurrent();

      expect(closed.leaves(), hasLength(2));
      expect(closed.root, isA<WindowSplit>());
      final WindowSplit root = closed.root as WindowSplit;
      expect(root.axis, SplitAxis.row);
      // The column collapsed down to leaf(1) directly (no 1-child split).
      expect(root.children.any((WindowNode n) => n is WindowSplit), isFalse);
      expect(
        closed.leaves().map((WindowLeaf l) => l.id).toSet(),
        <int>{1, 3},
      );
    });

    test('focus moves to a remaining leaf after close', () {
      final WindowTree tree =
          WindowTree.single(_buf('*scratch*'), id: 1).splitBelow();
      final WindowTree closed = tree.closeCurrent();
      expect(closed.leaves().map((WindowLeaf l) => l.id),
          contains(closed.focusedId));
    });

    test('no-op when focusedId does not name a leaf in the tree', () {
      final WindowTree tree =
          WindowTree.single(_buf('*scratch*'), id: 1).splitBelow();
      final WindowTree bogusFocus = WindowTree(tree.root, 99);
      expect(identical(bogusFocus.closeCurrent(), bogusFocus), isTrue);
    });
  });

  group('WindowTree — only (C-x 1)', () {
    test('no-op from a single-window tree', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'));
      expect(identical(tree.only(), tree), isTrue);
    });

    test('replaces the root with just the focused leaf', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'), id: 1)
          .splitBelow()
          .splitRight(); // some multi-window tree, focus still 1
      final WindowTree onlyView = tree.only();

      expect(onlyView.root, isA<WindowLeaf>());
      expect(onlyView.leaves(), hasLength(1));
      expect(onlyView.leaves().single.id, 1);
      expect(onlyView.focusedId, 1);
    });

    test('no-op when focusedId does not name a leaf in the tree', () {
      final WindowTree tree =
          WindowTree.single(_buf('*scratch*'), id: 1).splitBelow();
      final WindowTree bogusFocus = WindowTree(tree.root, 99);
      expect(identical(bogusFocus.only(), bogusFocus), isTrue);
    });
  });

  group('WindowTree — cycleFocus (C-x o)', () {
    test('no-op with a single window', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'));
      expect(identical(tree.cycleFocus(), tree), isTrue);
    });

    test('advances to the next leaf in traversal order and wraps around', () {
      final WindowTree tree = WindowTree.single(_buf('*scratch*'), id: 1)
          .splitBelow() // column[1, 2], focus 1
          .splitRight(); // row[column[1,2], 3]? actually splits leaf 1 -> row[1,3]... see below

      final List<int> ids = tree.leaves().map((WindowLeaf l) => l.id).toList();
      expect(ids, hasLength(3));

      WindowTree cur = WindowTree(tree.root, ids[0]);
      for (final int expectedNext in ids.sublist(1)) {
        cur = cur.cycleFocus();
        expect(cur.focusedId, expectedNext);
      }
      // Wraps back to the first id.
      cur = cur.cycleFocus();
      expect(cur.focusedId, ids[0]);
    });

    test('no-op when focusedId does not name a leaf in the tree', () {
      final WindowTree tree =
          WindowTree.single(_buf('*scratch*'), id: 1).splitBelow();
      final WindowTree bogusFocus = WindowTree(tree.root, 99);
      expect(identical(bogusFocus.cycleFocus(), bogusFocus), isTrue);
    });
  });
}
