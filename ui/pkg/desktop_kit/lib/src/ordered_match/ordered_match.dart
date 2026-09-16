// Ordered subsequence matching (helm/ivy default "fuzzy" style, NOT orderless).
//
// A query splits on whitespace into COMPONENTS that must match IN ORDER — each
// component's match starts at or after the previous one's — as if joined by
// `.*`. So for `vault-secret-approle`:
//   "v sec ap"             matches  (v … sec … ap, left to right)
//   "approle vault secret" does NOT (those substrings are present but out of
//                                    order)
// A top-level `|` gives ALTERNATIVE orderings; the candidate matches when ANY
// alternative matches:
//   "v sec ap|ap v sec"    matches `vault-secret-approle` via its first branch.
// Each component is a regexp (so `a.*b`, `\d+`, `[abc]` work); a component that
// is not a valid regexp is matched literally, so a half-typed pattern never
// blanks the list. Smart-case: case-insensitive unless the query has an
// uppercase letter. Pure; no Flutter, no IO.
library;

/// Whether [candidate] matches [query] under ordered-subsequence semantics
/// with top-level `|` alternatives. A blank query matches everything.
///
/// [caseSensitive] overrides the default SMART-case rule (case-insensitive
/// unless the query has an uppercase letter): pass `false` to force
/// case-insensitive matching — e.g. filename completion, where a file's case
/// should never matter — or `true` to force exact case.
bool orderedMatch(String candidate, String query, {bool? caseSensitive}) {
  final List<String> alts = _alternatives(query);
  if (alts.isEmpty) return true;
  final bool cs = caseSensitive ?? (query != query.toLowerCase());
  for (final String alt in alts) {
    if (_altMatches(candidate, alt, cs)) return true;
  }
  return false;
}

/// A relevance key for ranking matches of [query] within [candidate] (lower
/// sorts first): the earliest start among matching alternatives, then shorter
/// candidates, then alphabetical. Only meaningful for candidates that match.
({int at, int len, String s}) orderedRank(String candidate, String query,
    {bool? caseSensitive}) {
  final bool cs = caseSensitive ?? (query != query.toLowerCase());
  int best = 1 << 30;
  for (final String alt in _alternatives(query)) {
    final int at = _altStart(candidate, alt, cs);
    if (at >= 0 && at < best) best = at;
  }
  return (at: best, len: candidate.length, s: candidate);
}

List<String> _alternatives(String query) => query
    .split('|')
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList();

List<String> _components(String alt) =>
    alt.split(RegExp(r'\s+')).where((String s) => s.isNotEmpty).toList();

bool _altMatches(String candidate, String alt, bool caseSensitive) {
  final List<String> parts = _components(alt);
  if (parts.isEmpty) return true;
  final RegExp? re = _orderedRegExp(parts, caseSensitive);
  if (re != null) return re.hasMatch(candidate);
  return _orderedLiteral(candidate, parts, caseSensitive);
}

/// Start index of [alt]'s first component within [candidate] under ordered
/// matching, or -1 if it does not match.
int _altStart(String candidate, String alt, bool caseSensitive) {
  final List<String> parts = _components(alt);
  if (parts.isEmpty) return 0;
  final RegExp? re = _orderedRegExp(parts, caseSensitive);
  if (re != null) return re.firstMatch(candidate)?.start ?? -1;
  return _orderedLiteral(candidate, parts, caseSensitive)
      ? candidate.toLowerCase().indexOf(parts.first.toLowerCase())
      : -1;
}

/// Compile the components into one ordered regexp `c0.*c1.*…`, each component
/// used as a regexp when it compiles or escaped to a literal otherwise.
/// Returns null only if the assembled pattern itself fails to compile.
RegExp? _orderedRegExp(List<String> parts, bool caseSensitive) {
  final String src = parts.map(_componentSource).join('.*');
  try {
    return RegExp(src, caseSensitive: caseSensitive);
  } on FormatException {
    return null;
  }
}

/// A component's regexp source: itself if it is a valid regexp, else the
/// literal-escaped form (so `a-b`, `a[`, `a+b` typed as text still work).
String _componentSource(String part) {
  try {
    RegExp(part);
    return part;
  } on FormatException {
    return _escape(part);
  }
}

/// Ordered literal-substring fallback: each part found at or after the
/// previous part's end.
bool _orderedLiteral(String candidate, List<String> parts, bool caseSensitive) {
  final String hay = caseSensitive ? candidate : candidate.toLowerCase();
  int cursor = 0;
  for (final String part in parts) {
    final String needle = caseSensitive ? part : part.toLowerCase();
    final int i = hay.indexOf(needle, cursor);
    if (i < 0) return false;
    cursor = i + needle.length;
  }
  return true;
}

/// Escape [s] for use as a literal inside a regexp.
String _escape(String s) =>
    s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (Match m) => '\\${m[0]}');
