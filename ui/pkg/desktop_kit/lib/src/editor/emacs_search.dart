// A pure, headless Emacs-style search/replace model: literal (non-regexp)
// search with Emacs case-folding, wrapping forward/backward search,
// replace-next / replace-all, and an occur-style line listing — all over a
// plain Dart String with no Flutter dependency. The host owns the caret and
// the buffer; every entry point here takes text (+ an offset) and returns
// offsets or new text.
//
// [RegexSearch] extends the same surface to regular expressions, and
// [QueryReplaceSession] layers a pure, stepwise query-replace state machine on
// top of either engine for interactive (y/n/!) replace-driven UIs.
//
// WHICH REGEXP DIALECT [RegexSearch] SPEAKS IS NO LONGER FIXED. Every question
// routes through [RegexSearch.engine], a [RegexEngine]; the default is
// [DartRegexEngine] — Dart's [RegExp], ECMAScript semantics — which is what
// this file always did and is what the web target is stuck with. A host that
// can reach an Emacs-exact engine installs one, and the four constructs
// measured in `regex_engine.dart`'s header (`\(a\|b\)`, `[[:alpha:]]`,
// `a\{2,3\}`, `\sw`) stop silently reporting "no match".
library;

import 'regex_engine.dart';

export 'regex_engine.dart'
    show DartRegexEngine, RegexEngine, RegexMatchSpan, emacsFoldsCase;

/// A single match: a half-open offset range `[start, end)` into the searched
/// text. `end - start` is always the needle's length.
class SearchHit {
  const SearchHit(this.start, this.end);
  final int start, end;

  @override
  bool operator ==(Object other) =>
      other is SearchHit && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SearchHit($start, $end)';
}

/// Literal search over a String with Emacs semantics.
///
/// Case-folding follows Emacs `case-fold-search` + `search-upper-case`: an
/// all-lower-case needle matches case-insensitively, while a needle carrying
/// ANY upper-case character matches case-sensitively. An empty needle never
/// matches (Emacs re-uses the last search string instead; the host decides).
class Search {
  Search._();

  /// All matches of [needle] in [text] (case-insensitive when [needle] is all
  /// lower-case, Emacs-style). Empty needle -> empty list.
  ///
  /// Matches are **non-overlapping**, scanned left-to-right: after a hit the
  /// scan resumes at the hit's end, so `matches('aaa', 'aa')` yields one hit
  /// at `[0,2)`. This is the enumeration [replaceAll] and [occur] use, and it
  /// mirrors `replace-string`'s behaviour.
  static List<SearchHit> matches(String text, String needle) {
    if (needle.isEmpty) return const <SearchHit>[];
    final bool fold = _foldsCase(needle);
    final List<SearchHit> hits = <SearchHit>[];
    final int last = text.length - needle.length;
    int i = 0;
    while (i <= last) {
      if (_matchAt(text, needle, i, fold)) {
        hits.add(SearchHit(i, i + needle.length));
        i += needle.length;
      } else {
        i++;
      }
    }
    return hits;
  }

  /// Next match at/after [from], wrapping to 0. Null when none.
  ///
  /// Unlike [matches] this searches from [from] directly (an offset mid-way
  /// through the text is a legal starting point), so it can report a hit that
  /// the non-overlapping enumeration would skip. [from] is clamped into range.
  static SearchHit? forward(String text, int from, String needle) {
    if (needle.isEmpty) return null;
    final int start = from.clamp(0, text.length);
    return _searchFrom(text, needle, start) ?? _searchFrom(text, needle, 0);
  }

  /// Previous match strictly before [from], wrapping to end. Null when none.
  ///
  /// "Strictly before" is measured on the hit's **start**: the returned hit
  /// satisfies `hit.start < from`, which guarantees progress when the caret
  /// already sits on a hit's start (repeated `C-r` walks backwards). [from] is
  /// clamped into range.
  static SearchHit? backward(String text, int from, String needle) {
    if (needle.isEmpty) return null;
    final int start = from.clamp(0, text.length);
    return _searchBefore(text, needle, start) ??
        _searchBefore(text, needle, text.length + 1);
  }

  /// Replace the FIRST match at/after [from]; returns (text, caret) or null.
  ///
  /// Does NOT wrap (like `query-replace`, which stops at end of buffer): null
  /// when no match starts at/after [from]. The returned caret sits just after
  /// the inserted replacement.
  static ({String text, int caret})? replaceNext(
      String text, int from, String needle, String with_) {
    if (needle.isEmpty) return null;
    final int start = from.clamp(0, text.length);
    final SearchHit? hit = _searchFrom(text, needle, start);
    if (hit == null) return null;
    return (
      text: text.replaceRange(hit.start, hit.end, with_),
      caret: hit.start + with_.length,
    );
  }

  /// Replace every match; returns (text, count). Uses the non-overlapping
  /// enumeration of [matches], so the replacement text is never re-scanned.
  static ({String text, int count}) replaceAll(
      String text, String needle, String with_) {
    final List<SearchHit> hits = matches(text, needle);
    if (hits.isEmpty) return (text: text, count: 0);
    final StringBuffer out = StringBuffer();
    int prev = 0;
    for (final SearchHit h in hits) {
      out.write(text.substring(prev, h.start));
      out.write(with_);
      prev = h.end;
    }
    out.write(text.substring(prev));
    return (text: out.toString(), count: hits.length);
  }

  /// Every line containing a match, as 1-indexed (line, line text) pairs —
  /// the `occur` listing. A line is reported once no matter how many matches
  /// it holds; a match spanning a newline is attributed to the line it starts
  /// on. Line text excludes the trailing newline.
  static List<({int line, String text})> occur(String text, String needle) {
    final List<SearchHit> hits = matches(text, needle);
    if (hits.isEmpty) return <({int line, String text})>[];
    final List<String> lines = text.split('\n');
    final List<({int line, String text})> out = <({int line, String text})>[];
    // Walk hits (ascending) against line starts with a single moving cursor.
    int lineIndex = 0;
    int lineStart = 0;
    for (final SearchHit h in hits) {
      while (lineIndex < lines.length - 1 &&
          h.start >= lineStart + lines[lineIndex].length + 1) {
        lineStart += lines[lineIndex].length + 1;
        lineIndex++;
      }
      if (out.isEmpty || out.last.line != lineIndex + 1) {
        out.add((line: lineIndex + 1, text: lines[lineIndex]));
      }
    }
    return out;
  }

  /// First match starting at/after [start], or null. No wrapping.
  static SearchHit? _searchFrom(String text, String needle, int start) {
    final bool fold = _foldsCase(needle);
    final int last = text.length - needle.length;
    for (int i = start; i <= last; i++) {
      if (_matchAt(text, needle, i, fold)) {
        return SearchHit(i, i + needle.length);
      }
    }
    return null;
  }

  /// Last match starting strictly before [before], or null. No wrapping.
  static SearchHit? _searchBefore(String text, String needle, int before) {
    final bool fold = _foldsCase(needle);
    int i = text.length - needle.length;
    if (i > before - 1) i = before - 1;
    for (; i >= 0; i--) {
      if (_matchAt(text, needle, i, fold)) {
        return SearchHit(i, i + needle.length);
      }
    }
    return null;
  }

  /// Emacs rule: fold case only when the needle carries no upper-case char.
  /// Shared with the regexp path through [emacsFoldsCase] so the literal and
  /// regexp searches cannot drift apart on the one rule they both apply.
  static bool _foldsCase(String needle) => emacsFoldsCase(needle);

  static bool _matchAt(String text, String needle, int at, bool fold) {
    for (int j = 0; j < needle.length; j++) {
      final int a = text.codeUnitAt(at + j);
      final int b = needle.codeUnitAt(j);
      if (a == b) continue;
      if (!fold || _lowerUnit(a) != _lowerUnit(b)) return false;
    }
    return true;
  }

  /// Lower-case a single code unit, leaving it alone when the mapping is not
  /// 1:1 (e.g. U+0130) so offsets can never shift under the caret.
  static int _lowerUnit(int unit) {
    if (unit >= 0x41 && unit <= 0x5A) return unit + 0x20; // ASCII fast path
    if (unit < 0x80) return unit;
    final String s = String.fromCharCode(unit).toLowerCase();
    return s.length == 1 ? s.codeUnitAt(0) : unit;
  }
}

/// Outcome of compiling a search pattern: either it is usable ([ok]) or there
/// is a human-readable [error] string. Never throws — callers get a value they
/// can display directly in a minibuffer/echo-area style UI.
class RegexCompileResult {
  const RegexCompileResult._(this.regex, this.error, this.ok);

  /// The compiled Dart pattern when — and only when — the installed engine IS
  /// Dart's [RegExp]. Null under any other [RegexEngine], which cannot produce
  /// a [RegExp] at all.
  ///
  /// **Test [ok], not this.** A null here used to mean "did not compile"; it
  /// now also means "compiled, by an engine that is not RegExp". Kept only so
  /// a caller holding a Dart regex can still reach it.
  final RegExp? regex;

  /// A clean, displayable error message, or null when the pattern compiled
  /// (and also null for the empty pattern, which is "no search", not an error).
  final String? error;

  /// True when the pattern is usable for searching. False for the empty
  /// pattern and for one that did not compile.
  final bool ok;
}

/// Regex search over a String with the same incremental API surface as
/// [Search] (forward/backward from an offset, wrapping, all-hits
/// enumeration, replace-next/replace-all).
///
/// **Which regexp dialect this speaks is [engine]'s decision, not this
/// class's.** The default, [DartRegexEngine], is Dart's [RegExp] — ECMAScript
/// — which is what this class always used and is all the web target can have.
/// Install an Emacs-exact engine and the same call sites answer Emacs
/// questions; nothing else about the search UI changes. `regex_engine.dart`'s
/// header carries the measured table of what that fixes.
///
/// Case-folding mirrors [Search] and is applied by the engine, from the one
/// shared rule in [emacsFoldsCase]: a pattern containing no upper-case letter
/// matches case-insensitively; any upper-case letter makes the match
/// case-sensitive. Invalid patterns never throw past this API — every entry
/// point either returns null/empty or surfaces [RegexCompileResult]'s
/// [RegexCompileResult.error] string.
///
/// Zero-width matches (e.g. `a*` matching the empty string) are skipped
/// everywhere here so scans always make forward progress; a needle that can
/// only match the empty string reports no hits, exactly like an empty literal
/// needle in [Search]. That is a contract on [RegexEngine], not a filter
/// applied afterwards, so an engine cannot quietly opt out of it.
class RegexSearch {
  RegexSearch._();

  static RegexEngine _engine = const DartRegexEngine();

  /// The engine every question here routes through.
  ///
  /// Setting it is global and immediate; setting it to null restores
  /// [DartRegexEngine]. A host installs one once at startup, after checking
  /// that whatever backs it is actually reachable — an engine that cannot
  /// answer must not be installed, because there is no per-call fallback here
  /// and there should not be: a search that silently changes dialect
  /// mid-session is worse than one that consistently does not.
  static RegexEngine get engine => _engine;
  static set engine(RegexEngine? e) => _engine = e ?? const DartRegexEngine();

  /// Compile-check [pattern]. An empty pattern is "no search": [ok] is false
  /// and there is no error text, just as [Search] treats an empty literal
  /// needle.
  static RegexCompileResult compile(String pattern) {
    if (pattern.isEmpty) return const RegexCompileResult._(null, null, false);
    final String? err = _engine.errorFor(pattern);
    if (err != null) return RegexCompileResult._(null, err, false);
    // The RegExp is a courtesy for a caller holding the default engine; under
    // any other engine there is no RegExp to hand back and `ok` is the only
    // usable answer.
    RegExp? re;
    if (_engine is DartRegexEngine) {
      try {
        re = RegExp(pattern, caseSensitive: !emacsFoldsCase(pattern));
      } on FormatException {
        re = null;
      }
    }
    return RegexCompileResult._(re, null, true);
  }

  /// Convenience accessor for just the error text (null when [pattern]
  /// compiles, including the empty-pattern case).
  static String? errorFor(String pattern) =>
      pattern.isEmpty ? null : _engine.errorFor(pattern);

  /// All non-overlapping, non-zero-width matches of [pattern] in [text].
  static List<SearchHit> matches(String text, String pattern) {
    if (pattern.isEmpty) return const <SearchHit>[];
    return <SearchHit>[
      for (final RegexMatchSpan m in _engine.allMatches(text, pattern))
        SearchHit(m.start, m.end),
    ];
  }

  /// Next match at/after [from], wrapping to 0. Null when none or [pattern]
  /// is invalid/empty.
  static SearchHit? forward(String text, int from, String pattern) {
    if (pattern.isEmpty || _engine.errorFor(pattern) != null) return null;
    final int start = from.clamp(0, text.length);
    final RegexMatchSpan? m = _engine.firstMatchFrom(text, start, pattern) ??
        _engine.firstMatchFrom(text, 0, pattern);
    return m == null ? null : SearchHit(m.start, m.end);
  }

  /// Previous match strictly before [from], wrapping to end. Null when none
  /// or [pattern] is invalid/empty.
  static SearchHit? backward(String text, int from, String pattern) {
    if (pattern.isEmpty || _engine.errorFor(pattern) != null) return null;
    final int before = from.clamp(0, text.length);
    final RegexMatchSpan? m = _engine.lastMatchBefore(text, before, pattern) ??
        _engine.lastMatchBefore(text, text.length + 1, pattern);
    return m == null ? null : SearchHit(m.start, m.end);
  }

  /// Replace the FIRST match at/after [from]; returns (text, caret) or null
  /// (no match, or [pattern] is invalid/empty). Does NOT wrap.
  ///
  /// [with_] may reference capture groups from [pattern] using `$1`..`$9`
  /// (see [_expand] for the full substitution syntax).
  static ({String text, int caret})? replaceNext(
      String text, int from, String pattern, String with_) {
    if (pattern.isEmpty || _engine.errorFor(pattern) != null) return null;
    final int start = from.clamp(0, text.length);
    final RegexMatchSpan? m = _engine.firstMatchFrom(text, start, pattern);
    if (m == null) return null;
    final String rep = _expand(with_, m);
    return (
      text: text.replaceRange(m.start, m.end, rep),
      caret: m.start + rep.length,
    );
  }

  /// Replace every match; returns (text, count). Null-safe: an invalid or
  /// empty [pattern] returns the original text with a zero count.
  ///
  /// One enumeration, then string surgery — so under an out-of-process engine
  /// this is ONE round trip regardless of how many matches there are.
  static ({String text, int count}) replaceAll(
      String text, String pattern, String with_) {
    if (pattern.isEmpty || _engine.errorFor(pattern) != null) {
      return (text: text, count: 0);
    }
    final List<RegexMatchSpan> ms = _engine.allMatches(text, pattern);
    if (ms.isEmpty) return (text: text, count: 0);
    final StringBuffer out = StringBuffer();
    int prev = 0;
    for (final RegexMatchSpan m in ms) {
      out.write(text.substring(prev, m.start));
      out.write(_expand(with_, m));
      prev = m.end;
    }
    out.write(text.substring(prev));
    return (text: out.toString(), count: ms.length);
  }

  /// Expands a replacement [template] against a match's capture groups.
  ///
  /// Substitution syntax (documented choice — `$`-style, not `\`-style):
  ///   - `$1`..`$9`, or any run of digits `$<n>` -> [RegexMatchSpan.group] `n`
  ///     (empty string when that group didn't participate in the match).
  ///   - `$&` -> the whole match ([RegexMatchSpan.group] `0`).
  ///   - `$$` -> a literal `$`.
  ///   - Any other `$` (not followed by a digit, `&`, or `$`) is copied
  ///     through unchanged, so plain replacement text with a stray `$` is
  ///     never mangled.
  static String _expand(String template, RegexMatchSpan m) {
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < template.length) {
      final String c = template[i];
      if (c == r'$' && i + 1 < template.length) {
        final String next = template[i + 1];
        if (next == r'$') {
          out.write(r'$');
          i += 2;
          continue;
        }
        if (next == '&') {
          out.write(m.group(0) ?? '');
          i += 2;
          continue;
        }
        if (_isDigit(next)) {
          int j = i + 1;
          while (j < template.length && _isDigit(template[j])) j++;
          final int idx = int.parse(template.substring(i + 1, j));
          out.write(idx <= m.groupCount ? (m.group(idx) ?? '') : '');
          i = j;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static bool _isDigit(String c) {
    final int u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
  }
}

/// A pure, stepwise state machine for interactive `query-replace` /
/// `query-replace-regexp`: the host drives it one decision at a time
/// (`replaceCurrent` = `y`, `skip` = `n`, `replaceAll` = `!`, `quit` = `q`)
/// and reads [text]/[current]/[done] after each step to render the UI.
///
/// Construct with the buffer [text], a starting offset [from], the search
/// term [needle], the replacement [with_], and [regex] to select the engine.
/// The session does NOT wrap — like real `query-replace`, it walks forward
/// from [from] to the end of the buffer and then reports [done].
///
/// Capture-group substitution in regex mode uses the same `$1`/`$&`/`$$`
/// syntax as [RegexSearch.replaceNext]/[RegexSearch.replaceAll] (see
/// [RegexSearch._expand]).
class QueryReplaceSession {
  QueryReplaceSession(String text, int from, this.needle, this.with_,
      {this.regex = false})
      : _text = text,
        _pos = from.clamp(0, text.length) {
    _advance();
  }

  /// The search term (literal or regex source, per [regex]).
  final String needle;

  /// The replacement text (may contain `$1`-style group refs in regex mode).
  final String with_;

  /// True to search/replace via [RegexSearch]; false for literal [Search].
  final bool regex;

  String _text;
  int _pos;
  int _count = 0;
  bool _quit = false;
  SearchHit? _current;
  RegexMatchSpan? _currentMatch;
  String? _error;

  /// The buffer text, updated in place as replacements happen.
  String get text => _text;

  /// How many replacements have been made so far.
  int get replacedCount => _count;

  /// The current pending match, or null when there's nothing left to decide
  /// (buffer exhausted, session quit, or [needle] is invalid/empty).
  SearchHit? get current => _current;

  /// True once there is no pending match — either the buffer was exhausted,
  /// [quit] was called, or [needle] failed to compile (see [error]).
  bool get done => _current == null;

  /// True only when [done] was reached via an explicit [quit] call, as
  /// opposed to running off the end of the buffer.
  bool get quitRequested => _quit;

  /// Set when [regex] is true and [needle] failed to compile; null
  /// otherwise. A session with a live [error] is always [done].
  String? get error => _error;

  /// Accept the current match: replace it, advance past the replacement, and
  /// locate the next match. No-op when [done].
  void replaceCurrent() {
    final SearchHit? hit = _current;
    if (hit == null) return;
    final String rep = (regex && _currentMatch != null)
        ? RegexSearch._expand(with_, _currentMatch!)
        : with_;
    _text = _text.replaceRange(hit.start, hit.end, rep);
    _pos = hit.start + rep.length;
    _count++;
    _advance();
  }

  /// Reject the current match and locate the next one, leaving [text]
  /// untouched. No-op when [done].
  void skip() {
    final SearchHit? hit = _current;
    if (hit == null) return;
    _pos = hit.end > hit.start ? hit.end : hit.start + 1;
    _advance();
  }

  /// Replace the current match and every remaining match without further
  /// prompting (the `!` response). No-op when already [done].
  void replaceAll() {
    while (_current != null) {
      replaceCurrent();
    }
  }

  /// End the session without touching the current (or any later) match.
  void quit() {
    _current = null;
    _currentMatch = null;
    _quit = true;
  }

  void _advance() {
    if (_quit || _error != null) {
      _current = null;
      _currentMatch = null;
      return;
    }
    if (regex) {
      final RegexCompileResult r = RegexSearch.compile(needle);
      if (!r.ok) {
        _error = r.error;
        _current = null;
        _currentMatch = null;
        return;
      }
      final RegexMatchSpan? m =
          RegexSearch.engine.firstMatchFrom(_text, _pos, needle);
      _currentMatch = m;
      _current = m == null ? null : SearchHit(m.start, m.end);
    } else {
      _currentMatch = null;
      _current = Search._searchFrom(_text, needle, _pos);
    }
  }
}
