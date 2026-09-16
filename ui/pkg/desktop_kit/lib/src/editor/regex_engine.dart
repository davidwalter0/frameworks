// The seam that lets something OTHER than Dart's [RegExp] answer a regexp
// search — because Dart's RegExp is ECMAScript, and this is an Emacs editor.
//
// ---------------------------------------------------------------------------
// THE DEFECT THIS EXISTS FOR, MEASURED RATHER THAN ASSERTED.
//
// `RegexSearch.compile` handed the user's pattern to `RegExp` with NO
// translation. Emacs regexp syntax and ECMAScript regexp syntax disagree about
// the meaning of a backslash in almost every construct that matters, and the
// disagreement is SILENT: the pattern compiles, and reports no match.
//
// Measured with `dart run` on 2026-09-03, re-settled against an isolated
// `emacs -Q --batch` (GNU Emacs 30.2) on 2026-09-10 — both halves of this
// table are outputs, not recollections:
//
//	pattern         subject   GNU Emacs 30.2   Dart RegExp
//	\(a\|b\)        a         match [0,1)      NO MATCH
//	[[:alpha:]]+    abc       match [0,3)      NO MATCH
//	a\{2,3\}        aaa       match [0,3)      NO MATCH
//	\sw             x         match [0,1)      NO MATCH
//	\bfoo\b         foo       match [0,3)      match [0,3)   <- shared syntax
//
// Four of five core constructs returned a WRONG ANSWER. Not an error a user
// could act on — a confident "Failing I-search" for a pattern that matches.
// The fifth is the control: `\b` is spelled the same in both dialects, so it
// works, which is exactly why the defect reads as "regexp search is fine" until
// someone types a group.
//
// ---------------------------------------------------------------------------
// WHY A SEAM AND NOT A FIX IN PLACE.
//
// The obvious repair — translate Emacs syntax to ECMAScript before compiling —
// cannot be made correct. `\sw`/`\cC` need a SYNTAX TABLE and a CATEGORY TABLE,
// which are per-buffer, per-mode Emacs data with no ECMAScript equivalent;
// `\=`, `` \` ``, `\'`, `\_<`, `\_>` have no equivalent either; and the
// leftmost-then-backtrack preference order differs in cases a translation
// cannot reach. A translator would move the failures rather than remove them,
// and would move them somewhere harder to see.
//
// An Emacs-exact engine already exists — `github.com/davidwalter0/elisp`
// `pkg/regex`, gated against real GNU Emacs 30.2 — but it is Go, and it is
// therefore not available on every platform this kit runs on. So this file
// declares WHAT the search path needs, [DartRegexEngine] keeps the existing
// behaviour as the default, and a host that can reach a better engine installs
// one.
//
// ---------------------------------------------------------------------------
// THE DEFAULT DOES NOT CHANGE, DELIBERATELY.
//
// With no engine installed — which is every consumer of this kit today, and is
// permanently the case on WEB, where there is no subprocess to talk to — the
// Dart implementation runs and behaves exactly as it did. That is not
// timidity: the kit cannot depend on a Go binary, so ECMAScript semantics stay
// the floor, and the honest description of the result is "Emacs-correct where
// an Emacs engine is reachable, unchanged where it is not".
//
// A host installs one with `RegexSearch.engine = …`.
library;

/// One regexp match: a half-open `[start, end)` range into [text], plus the
/// capture groups.
///
/// This is the kit's own match type rather than Dart's [Match] because a
/// [RegexEngine] that is not Dart's [RegExp] cannot produce a [Match] — there
/// is no constructor for one — and the replacement-template expansion needs
/// group access. The subset of [Match]'s API reproduced here ([group],
/// [groupCount]) is exactly the subset the expansion uses.
class RegexMatchSpan {
  const RegexMatchSpan(this.text, this.start, this.end, this.groups);

  /// Convenience for a match with no capture groups.
  const RegexMatchSpan.plain(String text, int start, int end)
      : this(text, start, end, const <String?>[]);

  /// The subject the offsets index into. Held so [group] can answer group 0
  /// without the caller having to pass the text back in.
  final String text;

  /// The whole match, as code-unit offsets into [text].
  final int start, end;

  /// Groups 1..N as their matched TEXT, null for a group that did not
  /// participate.
  ///
  /// Text rather than offsets, because that is what the one consumer —
  /// replacement-template expansion — actually needs, and because Dart's
  /// [Match] exposes no per-group offsets to convert from. An engine that has
  /// offsets (the Go one does) resolves them to text at the boundary, where it
  /// still has the subject in hand.
  ///
  /// A non-participating group is KEPT as a null slot rather than dropped.
  /// Dropping it would renumber every later group, so `$3` in a replacement
  /// template would silently expand group 4 whenever group 2 did not match —
  /// the class of bug that only shows up on the input nobody tested.
  final List<String?> groups;

  /// The highest capturing-group number available, 0 when there are none.
  int get groupCount => groups.length;

  /// Group [i]'s text: `0` is the whole match, `1..groupCount` the captures,
  /// null when the group did not participate or does not exist.
  String? group(int i) {
    if (i == 0) return text.substring(start, end);
    if (i < 1 || i > groups.length) return null;
    return groups[i - 1];
  }

  @override
  String toString() => 'RegexMatchSpan($start, $end)';
}

/// Emacs's case-fold convention, in one place so both engines apply the same
/// rule: a pattern carrying NO upper-case character folds case; any upper-case
/// character makes the search case-sensitive.
///
/// This is `search-upper-case` as isearch applies it — a scan of the search
/// string, not an analysis of the compiled pattern. So `\S` (a syntax-class
/// negation, which is spelled with a capital) makes a search case-sensitive,
/// and it does in real Emacs too, for the same reason.
bool emacsFoldsCase(String pattern) => pattern == pattern.toLowerCase();

/// What the regexp search path needs from an engine.
///
/// The three query shapes are not "what a regexp API should offer" — they are
/// the three [RegexSearch] already asked of [RegExp], so that swapping the
/// engine changes the ANSWERS and nothing else about the search UI.
///
/// EVERY IMPLEMENTATION MUST SKIP ZERO-WIDTH MATCHES. `a*` matches the empty
/// string at every position; reporting those would highlight the whole buffer
/// and stop an incremental search from advancing. The Dart implementation has
/// always skipped them, so an engine that does not is not a drop-in.
///
/// Implementations are synchronous. An async engine would push a `Future`
/// through `EmacsBuffer.execute`, which is called from inside `setState`, and
/// that is a change to every consumer of the kit rather than to this seam.
abstract interface class RegexEngine {
  /// A displayable error for a pattern this engine cannot compile, or null
  /// when it compiles. An empty pattern is not an error — it is "no search" —
  /// and must answer null.
  String? errorFor(String pattern);

  /// Every non-overlapping, non-zero-width match, left to right.
  List<RegexMatchSpan> allMatches(String text, String pattern);

  /// The first non-zero-width match at or after [start]. Does not wrap.
  ///
  /// A zero-width match does not BLOCK: the scan steps past it, so a pattern
  /// that can match empty still finds its non-empty matches.
  RegexMatchSpan? firstMatchFrom(String text, int start, String pattern);

  /// The last match of [allMatches] whose START is strictly before [before],
  /// or null.
  ///
  /// "Strictly before", measured on the start, is what makes a repeated `C-r`
  /// walk backwards instead of sticking on the hit the caret already sits on.
  RegexMatchSpan? lastMatchBefore(String text, int before, String pattern);
}

/// The default engine: Dart's [RegExp], i.e. ECMAScript semantics.
///
/// Kept, and kept as the default, because it is the only engine available on
/// every platform this kit builds for — the web target has no subprocess to
/// reach a better one through. Its limits are the table in this file's header,
/// and they are limits of the ENGINE, not of this class.
class DartRegexEngine implements RegexEngine {
  const DartRegexEngine();

  RegExp? _compile(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      return RegExp(pattern, caseSensitive: !emacsFoldsCase(pattern));
    } on FormatException {
      return null;
    }
  }

  @override
  String? errorFor(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      RegExp(pattern, caseSensitive: !emacsFoldsCase(pattern));
      return null;
    } on FormatException catch (e) {
      return 'Invalid regexp: ${e.message}';
    }
  }

  @override
  List<RegexMatchSpan> allMatches(String text, String pattern) {
    final RegExp? re = _compile(pattern);
    if (re == null) return const <RegexMatchSpan>[];
    final List<RegexMatchSpan> out = <RegexMatchSpan>[];
    for (final Match m in re.allMatches(text)) {
      if (m.end > m.start) out.add(spanOf(text, m));
    }
    return out;
  }

  @override
  RegexMatchSpan? firstMatchFrom(String text, int start, String pattern) {
    final RegExp? re = _compile(pattern);
    if (re == null) return null;
    for (final Match m in re.allMatches(text, start.clamp(0, text.length))) {
      if (m.end > m.start) return spanOf(text, m);
    }
    return null;
  }

  @override
  RegexMatchSpan? lastMatchBefore(String text, int before, String pattern) {
    final RegExp? re = _compile(pattern);
    if (re == null) return null;
    RegexMatchSpan? found;
    for (final Match m in re.allMatches(text)) {
      if (m.end <= m.start) continue;
      if (m.start >= before) break;
      found = spanOf(text, m);
    }
    return found;
  }

  /// Converts a Dart [Match] into the kit's own span, preserving a
  /// non-participating group as a null slot so later groups keep their number.
  static RegexMatchSpan spanOf(String text, Match m) => RegexMatchSpan(
        text,
        m.start,
        m.end,
        <String?>[for (int i = 1; i <= m.groupCount; i++) m.group(i)],
      );
}
