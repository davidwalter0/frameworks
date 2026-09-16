/// Pure font-list parsing helpers, free of any host dependency.
///
/// Split out of `font_tools.dart` so the `dart:io` enumeration path can reuse
/// [parseFcList] inside an isolate without pulling the Flutter-facing library
/// (and its `FontWeight` import) across the isolate boundary.
library;

/// Parse `fc-list : family` stdout into a sorted, de-duplicated list of family
/// names.
///
/// Each line is comma-separated family aliases (canonical name first, then
/// localized aliases), with fc-list backslash-escaping literal '-', ',', '\'.
/// We keep ONLY the primary (first) name per line and drop the aliases —
/// otherwise localized CJK duplicates bloat the list ~3x.
List<String> parseFcList(String raw) {
  final Set<String> names = <String>{};
  for (final String line in raw.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    // Primary name = up to the first UNescaped comma.
    final String primary = trimmed.split(RegExp(r'(?<!\\),')).first;
    final String t = primary
        .replaceAllMapped(RegExp(r'\\(.)'), (Match m) => m.group(1)!)
        .trim();
    if (t.isNotEmpty) names.add(t);
  }
  return dedupSorted(names.toList());
}

/// Trim, drop empties, de-duplicate, and sort case-insensitively.
List<String> dedupSorted(List<String> xs) {
  final List<String> set = xs
      .map((String e) => e.trim())
      .where((String e) => e.isNotEmpty)
      .toSet()
      .toList();
  set.sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return set;
}
