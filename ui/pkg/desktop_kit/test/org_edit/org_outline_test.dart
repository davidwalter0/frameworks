// The org outline parser: heading tree, keywords, body, edge cases.
import 'package:desktop_kit/desktop_kit_org_edit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOrgOutline(kOrgTreeSample)', () {
    final List<OrgNode> roots = parseOrgOutline(kOrgTreeSample);

    test('two top-level headings', () {
      expect(roots, hasLength(2));
      expect(roots[0].title, 'Editor shell');
      expect(roots[0].level, 1);
      expect(roots[1].title, 'Go support binary');
    });

    test('nests level-2 and level-3 children', () {
      final OrgNode editor = roots[0];
      expect(
        editor.children.map((OrgNode n) => n.title),
        containsAll(<String>['Paint the caret', 'Org header theme']),
      );
      final OrgNode orgHeader = editor.children
          .firstWhere((OrgNode n) => n.title == 'Org header theme');
      expect(orgHeader.level, 2);
      expect(
        orgHeader.children.map((OrgNode n) => n.title),
        containsAll(
            <String>['Extract from config', 'Config-driven box and bullets']),
      );
      expect(orgHeader.children.first.level, 3);
    });

    test('keywords are stripped from the title and recorded', () {
      final OrgNode editor = roots[0];
      final OrgNode paint = editor.children
          .firstWhere((OrgNode n) => n.title == 'Paint the caret');
      expect(paint.keyword, 'DONE');
      expect(isDoneKeyword(paint.keyword), isTrue);

      final OrgNode header = editor.children
          .firstWhere((OrgNode n) => n.title == 'Org header theme');
      expect(header.keyword, 'TODO');
      expect(isDoneKeyword(header.keyword), isFalse);

      final OrgNode phase1 = roots[1]
          .children
          .firstWhere((OrgNode n) => n.title == 'Phase 1 — faces from Go');
      expect(phase1.keyword, 'NEXT');
    });

    test('body lines attach to their heading', () {
      expect(roots[0].body, contains('Harvest a config; drive a live editor.'));
    });
  });

  group('edge cases', () {
    test('text before the first heading is ignored', () {
      final List<OrgNode> r = parseOrgOutline('preamble\n* H1\nbody');
      expect(r, hasLength(1));
      expect(r.single.title, 'H1');
      expect(r.single.body, <String>['body']);
    });

    test('a level jump (1 -> 3) still nests under the level 1', () {
      final List<OrgNode> r = parseOrgOutline('* A\n*** deep');
      expect(r.single.children.single.title, 'deep');
      expect(r.single.children.single.level, 3);
    });

    test('empty input yields no nodes', () {
      expect(parseOrgOutline(''), isEmpty);
    });
  });
}
