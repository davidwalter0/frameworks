// A tiny org-mode OUTLINE parser: turns org text into a heading tree. Pure Dart,
// demo-grade — it understands `*`-prefixed headings, an optional leading TODO/
// DONE keyword, and the non-heading lines that fall under each heading as body.
// Enough to render an org document as the raised-box heading tree the org header
// theme describes; NOT a full org parser (no properties, tables, timestamps).
library;

/// One node in the org outline tree.
class OrgNode {
  const OrgNode({
    required this.level,
    required this.title,
    this.keyword,
    this.body = const <String>[],
    this.children = const <OrgNode>[],
  });

  /// Heading depth (1 = `*`, 2 = `**`, …).
  final int level;

  /// The heading text, with the stars and any leading keyword removed.
  final String title;

  /// A leading `TODO` / `DONE` (etc.) keyword, or null.
  final String? keyword;

  /// Non-heading lines that appear under this heading (before its children),
  /// trimmed; blank lines are dropped.
  final List<String> body;

  /// Sub-headings (deeper levels).
  final List<OrgNode> children;
}

/// Keywords recognised at the head of a heading (colourised as todo/done).
const Set<String> _kTodoKeywords = <String>{
  'TODO',
  'NEXT',
  'WAIT',
  'HOLD',
};
const Set<String> _kDoneKeywords = <String>{'DONE', 'CANCELLED', 'KILL'};

/// Whether [word] is a recognised org todo/done keyword.
bool isOrgKeyword(String word) =>
    _kTodoKeywords.contains(word) || _kDoneKeywords.contains(word);

/// Whether [keyword] marks a heading as done.
bool isDoneKeyword(String? keyword) =>
    keyword != null && _kDoneKeywords.contains(keyword);

/// Parse [text] into the top-level [OrgNode]s (each with nested children).
///
/// A heading is a line matching `^\*+ +…`; a leading `TODO`/`DONE` word becomes
/// [OrgNode.keyword]. Any other non-blank line is appended to the current
/// heading's [OrgNode.body]; text before the first heading is ignored.
List<OrgNode> parseOrgOutline(String text) {
  final RegExp headingRe = RegExp(r'^(\*+)\s+(.*)$');
  final List<_Mutable> roots = <_Mutable>[];
  final List<_Mutable> stack = <_Mutable>[];

  for (final String line in text.split('\n')) {
    final RegExpMatch? m = headingRe.firstMatch(line);
    if (m != null) {
      final int level = m.group(1)!.length;
      String rest = m.group(2)!.trim();
      String? keyword;
      final int sp = rest.indexOf(' ');
      final String first = sp < 0 ? rest : rest.substring(0, sp);
      if (isOrgKeyword(first)) {
        keyword = first;
        rest = sp < 0 ? '' : rest.substring(sp + 1).trim();
      }
      final _Mutable node = _Mutable(level, rest, keyword);
      // Pop to the parent: the nearest ancestor with a shallower level.
      while (stack.isNotEmpty && stack.last.level >= level) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        roots.add(node);
      } else {
        stack.last.children.add(node);
      }
      stack.add(node);
    } else if (line.trim().isNotEmpty && stack.isNotEmpty) {
      stack.last.body.add(line.trim());
    }
  }
  return <OrgNode>[for (final _Mutable n in roots) n.freeze()];
}

class _Mutable {
  _Mutable(this.level, this.title, this.keyword);
  final int level;
  final String title;
  final String? keyword;
  final List<String> body = <String>[];
  final List<_Mutable> children = <_Mutable>[];

  OrgNode freeze() => OrgNode(
        level: level,
        title: title,
        keyword: keyword,
        body: List<String>.unmodifiable(body),
        children: <OrgNode>[for (final _Mutable c in children) c.freeze()],
      );
}

/// A realistic org document with a few heading levels, keywords and body text,
/// used by the Org tree card.
const String kOrgTreeSample = '''
* Editor shell
  Harvest a config; drive a live editor.
** DONE Paint the caret
   Overlay, not inline — no wobble, no eaten newline.
** TODO Org header theme
*** DONE Extract from config
    org-level-1..9, box, David/starlit block.
*** TODO Config-driven box and bullets
* Go support binary
** Seam
   Go decides what; Dart decides how it looks.
** NEXT Phase 1 — faces from Go
   Behind the FaceSpan contract.
''';
