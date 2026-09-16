// Helpers for the Appearance font picker: platform detection, PATH probing,
// system font enumeration, and a curated per-platform fallback list.
//
// The host-touching parts (PATH scan, fc-list, off-isolate parse) live behind
// the conditional import in font_enumeration_default.dart; everything in this
// library is pure and unit-testable. Ported from alert-log's
// font_tools (the bundled-font floor is dropped — desktop_kit bundles no fonts).
library;

import 'package:flutter/material.dart' show FontWeight;

import '../host/host_env_default.dart';
import 'font_enumeration_default.dart' as host_fonts;
import 'font_parsing.dart';

export 'font_parsing.dart' show parseFcList;

/// Platform tag — 'macos' | 'windows' | 'linux' | 'other'.
///
/// A browser reports `'other'`, which selects the empty curated list and leaves
/// only the floor families — the honest answer, since no host font list is
/// obtainable there.
String currentFontOs() => hostEnv.os.fontTag;

/// True when [exe] resolves on the current PATH (handles the Windows `;`
/// separator and executable extensions).
///
/// Always false on hosts with no process facility.
bool isOnPath(String exe) => host_fonts.isOnPath(exe);

/// Families always offered regardless of enumeration — the CSS generic
/// families Flutter maps on every platform, plus Noto. Keeps a sane default
/// even when enumeration is unavailable, which on web it always is.
const List<String> _floorFamilies = <String>[
  'sans-serif',
  'serif',
  'monospace',
  'Noto Sans',
  'Noto Serif',
];

/// Case-insensitive substring filter over [families], capped at [limit].
/// Empty query returns the first [limit] families (floor families first).
/// Pure + cheap — safe to call per keystroke even for a few thousand families.
List<String> filterFonts(
  List<String> families,
  String query, {
  int limit = 60,
}) {
  final String q = query.trim().toLowerCase();
  final List<String> out = <String>[];
  for (final String f in families) {
    if (q.isEmpty || f.toLowerCase().contains(q)) {
      out.add(f);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/// Enumerate system font families.
///
/// On Linux, runs `fc-list : family` if fc-list is on PATH, parses unique
/// family names off the UI isolate, and merges with [_floorFamilies]. On
/// macOS/Windows, when fc-list is absent, or on any host without a process
/// facility (every browser), returns a curated fallback list merged with
/// [_floorFamilies]. Never throws.
Future<List<String>> systemFontFamilies() async {
  final List<String> enumerated = await host_fonts.enumerateHostFontFamilies();
  if (enumerated.isNotEmpty) return _floorFirst(enumerated);
  return _floorFirst(_curatedFallback(currentFontOs()));
}

/// Returns the floor families first (in declared order), then the rest sorted.
List<String> _floorFirst(List<String> rest) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String f in _floorFamilies) {
    if (seen.add(f.toLowerCase())) out.add(f);
  }
  for (final String f in dedupSorted(rest)) {
    if (seen.add(f.toLowerCase())) out.add(f);
  }
  return out;
}

List<String> _curatedFallback(String os) {
  const List<String> mac = <String>[
    'Arial',
    'Courier New',
    'Georgia',
    'Helvetica',
    'Helvetica Neue',
    'Menlo',
    'Monaco',
    'SF Mono',
    'SF Pro',
    'Times New Roman',
  ];
  const List<String> win = <String>[
    'Arial',
    'Consolas',
    'Courier New',
    'Segoe UI',
    'Tahoma',
    'Times New Roman',
    'Verdana',
  ];
  const List<String> lin = <String>[
    'DejaVu Sans',
    'DejaVu Sans Mono',
    'DejaVu Serif',
    'Liberation Mono',
    'Liberation Sans',
    'Liberation Serif',
    'Noto Sans Mono',
    'Ubuntu',
    'Ubuntu Mono',
  ];
  return switch (os) {
    'macos' => mac,
    'windows' => win,
    'linux' => lin,
    _ => const <String>[],
  };
}

/// Trailing weight word → [FontWeight]. fontconfig (and GNOME's `font-name`)
/// expose a weight-named family like "Cantarell Light", but Flutter matches a
/// font's BASE family ("Cantarell") plus a separate fontWeight — so a
/// weight-named fontFamily string never matches and silently falls back.
/// [splitFamilyWeight] recovers the base family + weight so the chosen face
/// actually renders.
const Map<String, FontWeight> _weightWords = <String, FontWeight>{
  'thin': FontWeight.w100,
  'extralight': FontWeight.w200,
  'xlight': FontWeight.w200,
  'ultralight': FontWeight.w200,
  'light': FontWeight.w300,
  'demilight': FontWeight.w300,
  'semilight': FontWeight.w300,
  'regular': FontWeight.w400,
  'normal': FontWeight.w400,
  'book': FontWeight.w400,
  'medium': FontWeight.w500,
  'semibold': FontWeight.w600,
  'demibold': FontWeight.w600,
  'bold': FontWeight.w700,
  'extrabold': FontWeight.w800,
  'ultrabold': FontWeight.w800,
  'black': FontWeight.w900,
  'heavy': FontWeight.w900,
};

/// Split a (possibly weight-named) family into its base family and the weight,
/// or `null` weight when the trailing word isn't a recognised weight. Handles
/// one-word ("… Light") and two-word ("… Extra Light") suffixes. An empty or
/// blank input yields `('', null)`.
(String, FontWeight?) splitFamilyWeight(String name) {
  final String n = name.trim();
  if (n.isEmpty) return ('', null);
  final List<String> words = n.split(RegExp(r'\s+'));
  if (words.length >= 2) {
    final FontWeight? one = _weightWords[words.last.toLowerCase()];
    if (one != null) {
      return (words.sublist(0, words.length - 1).join(' '), one);
    }
    if (words.length >= 3) {
      final FontWeight? two =
          _weightWords[(words[words.length - 2] + words.last).toLowerCase()];
      if (two != null) {
        return (words.sublist(0, words.length - 2).join(' '), two);
      }
    }
  }
  return (n, null);
}
