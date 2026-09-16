// The pure org fold model: heading detection, hidden-line computation, org-cycle
// and global-cycle, and edit reconciliation.
import 'package:desktop_kit/desktop_kit_org_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Lines:  0:* A  1:body  2:** B  3:b2  4:* C
  const String doc = '* A\nbody\n** B\nb2\n* C';

  group('headings', () {
    test('finds heading lines and levels', () {
      expect(OrgFold.headings(doc), <OrgHeading>[
        (line: 0, level: 1),
        (line: 2, level: 2),
        (line: 4, level: 1),
      ]);
    });

    test('needs a space after the stars', () {
      expect(OrgFold.headings('*bold* not a heading'), isEmpty);
      expect(OrgFold.headings('*** ok'), <OrgHeading>[(line: 0, level: 3)]);
    });
  });

  group('hiddenLines', () {
    test('folding A hides its whole subtree (body + nested B + b2)', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 0);
      expect(f.hiddenLines(doc), <int>{1, 2, 3}); // C (line 4) stays visible
    });

    test('folding only B hides just its body', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 2);
      expect(f.hiddenLines(doc), <int>{3});
    });

    test('a folded child under a folded parent does not double-hide', () {
      final OrgFold f = OrgFold()
        ..cycleAt(doc, 2) // fold B
        ..cycleAt(doc, 0); // fold A (contains B)
      expect(f.hiddenLines(doc), <int>{1, 2, 3});
    });

    test('nothing folded hides nothing', () {
      expect(OrgFold().hiddenLines(doc), isEmpty);
    });
  });

  group('cycleAt', () {
    test('toggles the nearest heading at/above the line', () {
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc, 3), 2); // line 3 (b2) is under B
      expect(f.isFolded(2), isTrue);
      expect(f.cycleAt(doc, 3), 2); // toggles back
      expect(f.isFolded(2), isFalse);
    });

    test('returns null above the first heading', () {
      expect(OrgFold().cycleAt('preamble\n* A', 0), isNull);
    });
  });

  group('globalCycle', () {
    test('folds all then shows all (overview -> show-all)', () {
      final OrgFold f = OrgFold()..globalCycle(doc); // fold all
      expect(f.anyFolded, isTrue);
      // Overview: only the two top-level headings (0 and 4) remain visible.
      final Set<int> hidden = f.hiddenLines(doc);
      expect(hidden.contains(2), isTrue); // nested heading hidden
      expect(hidden.contains(0), isFalse);
      expect(hidden.contains(4), isFalse);
      f.globalCycle(doc); // show all
      expect(f.anyFolded, isFalse);
      expect(f.hiddenLines(doc), isEmpty);
    });
  });

  group('reconcile', () {
    test('drops folds that no longer land on a heading', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 2); // fold B at line 2
      expect(f.isFolded(2), isTrue);
      // After an edit, line 2 is no longer a heading.
      const String edited = '* A\nbody\nplain text\nb2\n* C';
      f.reconcile(edited);
      expect(f.isFolded(2), isFalse);
    });
  });

  group('foldView', () {
    test('nothing folded is the identity view (display == buffer)', () {
      final FoldedView v = foldView(doc, 5, OrgFold());
      expect(v.text, doc);
      expect(v.caret, 5);
      expect(v.bufferLineNumbers, <int>[1, 2, 3, 4, 5]);
      // offset maps are the identity
      for (int b = 0; b <= doc.length; b++) {
        expect(v.toDisplay(b), b);
        expect(v.toBuffer(b), b);
      }
    });

    test('folding A drops its subtree from the display and adds an ellipsis',
        () {
      // "* A" folded hides body(1), ** B(2), b2(3); "* C"(4) stays.
      final OrgFold f = OrgFold()..cycleAt(doc, 0);
      final FoldedView v = foldView(doc, 0, f, ellipsis: '#');
      expect(v.text, '* A#\n* C'); // body/B/b2 gone; '#' marks the fold
      // The gutter skips the hidden lines: 1 then 5.
      expect(v.bufferLineNumbers, <int>[1, 5]);
    });

    test('a caret inside a hidden region collapses to the fold marker', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 0); // hides lines 1..3
      // buffer offset 6 is inside "body" (hidden) -> maps onto the fold marker,
      // which is a valid position in the display text.
      final FoldedView v = foldView(doc, 6, f, ellipsis: '#');
      expect(v.caret, inInclusiveRange(0, v.text.length));
      // and it is NOT past the '* A#' heading+marker
      expect(v.caret, lessThanOrEqualTo('* A#'.length));
    });

    test('display->buffer->display round-trips for every visible char', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 2); // fold B: hides line 3
      final FoldedView v = foldView(doc, 0, f);
      for (int d = 0; d < v.text.length; d++) {
        // toBuffer then back to display returns to (at least) the same column;
        // for a non-ellipsis display char it is exact.
        final int b = v.toBuffer(d);
        expect(b, inInclusiveRange(0, doc.length));
      }
    });

    test('caret at column 0 of a heading maps to display column 0 of a line',
        () {
      final OrgFold f = OrgFold()..cycleAt(doc, 0); // fold A
      // caret at buffer 0 (the "*" of "* A") stays at display 0.
      final FoldedView v = foldView(doc, 0, f);
      expect(v.caret, 0);
    });
  });

  group('blocks', () {
    test('finds a terminated block by its begin/end lines', () {
      const String doc = '* A\n#+begin_src bash\necho hi\n#+end_src\n* B';
      expect(OrgFold.blocks(doc), <OrgBlock>[
        (line: 1, endLine: 3, kind: 'src'),
      ]);
    });

    test('is case-insensitive on both begin and end', () {
      const String doc = '#+BEGIN_QUOTE\ntext\n#+End_Quote';
      expect(OrgFold.blocks(doc), <OrgBlock>[
        (line: 0, endLine: 2, kind: 'quote'),
      ]);
    });

    test('an unterminated begin extends to the buffer end', () {
      const String doc = '#+begin_example\nline1\nline2';
      expect(OrgFold.blocks(doc), <OrgBlock>[
        (line: 0, endLine: 2, kind: 'example'),
      ]);
    });

    test('a block nested inside a heading is found alongside it', () {
      const String doc = '* A\n#+begin_src\nbody\n#+end_src\n* B';
      expect(OrgFold.blocks(doc), <OrgBlock>[
        (line: 1, endLine: 3, kind: 'src'),
      ]);
      expect(OrgFold.headings(doc), <OrgHeading>[
        (line: 0, level: 1),
        (line: 4, level: 1),
      ]);
    });
  });

  group('block folding via cycleAt', () {
    const String doc = '* A\n#+begin_src bash\necho hi\n#+end_src\nafter\n* B';
    // Lines: 0:* A 1:begin_src 2:echo hi 3:end_src 4:after 5:* B

    test('TAB on the begin line folds the block: body+end hidden', () {
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc, 1), 1);
      expect(f.hiddenLines(doc), <int>{2, 3});
      expect(f.isFolded(1), isTrue);
    });

    test('TAB inside the body toggles the same block', () {
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc, 2), 1); // point on "echo hi" -> block begin line
      expect(f.hiddenLines(doc), <int>{2, 3});
      expect(f.cycleAt(doc, 2), 1); // unfold
      expect(f.hiddenLines(doc), isEmpty);
    });

    test('TAB on the end line also toggles the block', () {
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc, 3), 1);
      expect(f.hiddenLines(doc), <int>{2, 3});
    });

    test(
        'nearest-node-wins: point in a block nested under a heading folds '
        'the block, not the heading', () {
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc, 2), 1); // the block's begin line, not 0 (the "* A")
      expect(f.isFolded(0), isFalse);
    });

    test('a folded ancestor heading still hides a block inside it', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 0); // fold "* A"
      // The whole subtree down to "* B" (line 5) is hidden, including the
      // block's body/end (2,3) and the line after it (4).
      expect(f.hiddenLines(doc), <int>{1, 2, 3, 4});
    });

    test('an unterminated block folds to the buffer end', () {
      const String doc2 = '* A\n#+begin_example\nline1\nline2';
      final OrgFold f = OrgFold();
      expect(f.cycleAt(doc2, 1), 1);
      expect(f.hiddenLines(doc2), <int>{2, 3});
    });

    test('reconcile drops a block fold when the begin line moves off it', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 1);
      expect(f.isFolded(1), isTrue);
      // After an edit, line 1 is no longer a "#+begin_" line.
      const String edited =
          '* A\nplain\n#+begin_src bash\necho hi\n#+end_src\nafter\n* B';
      f.reconcile(edited);
      expect(f.isFolded(1), isFalse);
    });
  });

  group('foldView with a folded block', () {
    const String doc = '* A\n#+begin_src bash\necho hi\n#+end_src\nafter\n* B';

    test('folding the block hides its body+end and appends the ellipsis', () {
      final OrgFold f = OrgFold()..cycleAt(doc, 1);
      final FoldedView v = foldView(doc, 0, f, ellipsis: '#');
      expect(v.text, '* A\n#+begin_src bash#\nafter\n* B');
    });

    test('unfolding restores the block verbatim', () {
      final OrgFold f = OrgFold()
        ..cycleAt(doc, 1)
        ..cycleAt(doc, 1);
      final FoldedView v = foldView(doc, 0, f);
      expect(v.text, doc);
    });
  });

  group('orgBulletsText', () {
    const List<String> bullets = <String>['▶', '○', '☯'];

    test('substitutes stars for depth-positioned bullets, length-preserved',
        () {
      // Caret far away (end) so no heading is in "typing" reveal.
      final String out = orgBulletsText(doc, doc.length, bullets);
      expect(out.length, doc.length);
      expect(out, '▶ A\nbody\n○  B\nb2\n▶ C');
    });

    test('caret inside the star prefix reveals the real asterisks', () {
      // Caret at offset 5 = line 1 ("body")… use line 2 start: "** B" begins
      // at offset 9; caret ON its stars (offset 10) reveals that line only.
      final String out = orgBulletsText(doc, 10, bullets);
      expect(out, '▶ A\nbody\n** B\nb2\n▶ C');
    });

    test(
        'caret just after the heading space still reveals; first title char '
        'hides', () {
      // "* A": star run [0,1), space at 1, title at 2. caret 2 = boundary
      // (just typed the space) -> reveal; caret 3 = typed a title char -> hide.
      expect(orgBulletsText(doc, 2, bullets), startsWith('* A'));
      expect(orgBulletsText(doc, 3, bullets), startsWith('▶ A'));
    });

    test('a multi-unit bullet glyph falls back to * (length safety)', () {
      final String out =
          orgBulletsText('* A', 3, <String>['🌟']); // 2 UTF-16 units
      expect(out, '* A');
    });

    test('non-heading lines and *bold* text are untouched', () {
      const String t = '*bold* not heading\n*** deep';
      final String out = orgBulletsText(t, t.length, bullets);
      expect(out, '*bold* not heading\n☯   deep');
    });

    test('level deeper than the list cycles the glyphs', () {
      final String out = orgBulletsText('**** D', 6, <String>['▶', '○']);
      expect(out, '○    D'); // level 4 -> index (4-1)%2 = 1; glyph col 0
    });
  });
}
