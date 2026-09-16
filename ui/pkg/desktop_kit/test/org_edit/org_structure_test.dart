import 'package:desktop_kit/desktop_kit_org_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('insertHeadingAfter', () {
    test('on a heading line inserts a same-level sibling right below it', () {
      const String text = '* One\nbody\n* Two\n';
      final int caret = text.indexOf('* One');
      final OrgEdit e = insertHeadingAfter(text, caret);
      expect(e.text, '* One\n* \nbody\n* Two\n');
      expect(e.text.substring(e.caret - 2, e.caret), '* ');
      expect(e.text[e.caret], '\n');
    });

    test('on a body line uses the enclosing heading level', () {
      const String text = '** Sub\nbody line\nmore\n';
      final int caret = text.indexOf('body line') + 2;
      final OrgEdit e = insertHeadingAfter(text, caret);
      expect(e.text, '** Sub\nbody line\n** \nmore\n');
    });

    test('with no enclosing heading defaults to level 1', () {
      const String text = 'plain line\nnext\n';
      final OrgEdit e = insertHeadingAfter(text, 0);
      expect(e.text, 'plain line\n* \nnext\n');
      expect(e.text.substring(e.caret - 2, e.caret), '* ');
    });

    test('at the last line (no trailing newline) still inserts below', () {
      const String text = '* Only';
      final OrgEdit e = insertHeadingAfter(text, 2);
      expect(e.text, '* Only\n* ');
      expect(e.caret, e.text.length);
    });
  });

  group('promoteHeading / demoteHeading', () {
    test('promote removes one star and keeps title text', () {
      const String text = '*** Deep title\n';
      final int caret = text.indexOf('Deep');
      final OrgEdit e = promoteHeading(text, caret);
      expect(e.text, '** Deep title\n');
    });

    test('demote adds one star', () {
      const String text = '* Top\n';
      final OrgEdit e = demoteHeading(text, 0);
      expect(e.text, '** Top\n');
    });

    test('promote clamps at level 1 (no-op)', () {
      const String text = '* Top\n';
      final OrgEdit e = promoteHeading(text, 0);
      expect(e.text, text);
      expect(e.caret, 0);
    });

    test('demote clamps at level 9 (no-op)', () {
      final String text = '${'*' * 9} Deepest\n';
      final OrgEdit e = demoteHeading(text, 0);
      expect(e.text, text);
      expect(e.caret, 0);
    });

    test('no-op off a heading line', () {
      const String text = 'not a heading\n';
      final OrgEdit e = promoteHeading(text, 3);
      expect(e.text, text);
      expect(e.caret, 3);
    });

    test('caret before the changed stars is unaffected', () {
      const String text = '*** Title\n';
      final OrgEdit e = promoteHeading(text, 0);
      expect(e.caret, 0);
    });

    test('caret in the title tracks the star-count delta', () {
      const String text = '** Title\n';
      final int caret = text.indexOf('Title');
      final OrgEdit e = demoteHeading(text, caret);
      expect(e.text, '*** Title\n');
      expect(e.caret, caret + 1);
      expect(e.text.substring(e.caret, e.caret + 5), 'Title');
    });

    test('promote then demote round-trips text and caret', () {
      const String text = '*** Title here\n';
      final int caret = text.indexOf('here');
      final OrgEdit promoted = promoteHeading(text, caret);
      final OrgEdit back = demoteHeading(promoted.text, promoted.caret);
      expect(back.text, text);
      expect(back.caret, caret);
    });
  });

  group('todoCycle', () {
    test('none -> TODO -> DONE -> none', () {
      const String text = '* Task\n';
      final OrgEdit t1 = todoCycle(text, 0);
      expect(t1.text, '* TODO Task\n');
      final OrgEdit t2 = todoCycle(t1.text, 0);
      expect(t2.text, '* DONE Task\n');
      final OrgEdit t3 = todoCycle(t2.text, 0);
      expect(t3.text, '* Task\n');
    });

    test('operates on the enclosing heading from a body line', () {
      const String text = '* Task\nsome body text\n';
      final int caret = text.indexOf('body');
      final OrgEdit e = todoCycle(text, caret);
      expect(e.text, '* TODO Task\nsome body text\n');
    });

    test('no-op with no enclosing heading', () {
      const String text = 'plain text only\n';
      final OrgEdit e = todoCycle(text, 3);
      expect(e.text, text);
      expect(e.caret, 3);
    });

    test('caret in the title shifts by the keyword-length delta', () {
      const String text = '* Task\n';
      final int caret = text.indexOf('Task');
      final OrgEdit e = todoCycle(text, caret);
      expect(e.text, '* TODO Task\n');
      expect(e.caret, caret + 5); // 'TODO ' = 5 chars
      expect(e.text.substring(e.caret, e.caret + 4), 'Task');
    });

    test('a title that merely starts with "TODO" as a word is not a keyword',
        () {
      const String text = '* TODOing the thing\n';
      final OrgEdit e = todoCycle(text, 0);
      expect(e.text, '* TODO TODOing the thing\n');
    });
  });

  group('moveSubtreeUp / moveSubtreeDown', () {
    const String text =
        '* One\nbody one\n* Two\nbody two\n* Three\nbody three\n';

    test('moveSubtreeUp swaps with the previous sibling', () {
      final int caret = text.indexOf('Two');
      final OrgEdit e = moveSubtreeUp(text, caret);
      expect(e.text, '* Two\nbody two\n* One\nbody one\n* Three\nbody three\n');
      expect(e.text.substring(e.caret, e.caret + 3), 'Two');
    });

    test('moveSubtreeDown swaps with the next sibling', () {
      final int caret = text.indexOf('Two');
      final OrgEdit e = moveSubtreeDown(text, caret);
      expect(e.text, '* One\nbody one\n* Three\nbody three\n* Two\nbody two\n');
      expect(e.text.substring(e.caret, e.caret + 3), 'Two');
    });

    test('moveSubtreeUp on the first sibling is a no-op', () {
      final int caret = text.indexOf('One');
      final OrgEdit e = moveSubtreeUp(text, caret);
      expect(e.text, text);
      expect(e.caret, caret);
    });

    test('moveSubtreeDown on the last sibling is a no-op', () {
      final int caret = text.indexOf('Three');
      final OrgEdit e = moveSubtreeDown(text, caret);
      expect(e.text, text);
      expect(e.caret, caret);
    });

    test('caret inside body text tracks the subtree it belongs to', () {
      final int caret = text.indexOf('body two') + 2;
      final OrgEdit e = moveSubtreeUp(text, caret);
      // "* Two\nbody two\n" now sits first; caret offset within that block
      // is preserved.
      final int expected = e.text.indexOf('body two') + 2;
      expect(e.caret, expected);
    });

    test('a heading after the swapped region keeps the same offset', () {
      // Moving Two up swaps the One/Two region; Three's subtree sits
      // entirely after it, so its buffer offset (and a caret placed there)
      // does not move.
      final int caretInThree = text.indexOf('body three');
      final OrgEdit e = moveSubtreeUp(text, text.indexOf('Two'));
      expect(e.text.length, text.length);
      expect(e.text.indexOf('body three'), caretInThree);
    });

    test('no-op with no enclosing heading', () {
      const String plain = 'no headings here\n';
      final OrgEdit e = moveSubtreeUp(plain, 3);
      expect(e.text, plain);
      expect(e.caret, 3);
      final OrgEdit e2 = moveSubtreeDown(plain, 3);
      expect(e2.text, plain);
      expect(e2.caret, 3);
    });

    test('nested subtrees move as a whole with their parent', () {
      const String nested = '* A\n** A1\n** A2\n* B\nbody b\n';
      final int caret = nested.indexOf('* B');
      final OrgEdit e = moveSubtreeUp(nested, caret);
      expect(e.text, '* B\nbody b\n* A\n** A1\n** A2\n');
    });
  });
}
