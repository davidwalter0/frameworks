// Pure minibuffer completion model, Emacs-style.
//
// No Flutter imports — this is a plain Dart model, unit-testable in
// isolation from the widget layer. `emacs_buffer_editor.dart` (or any
// minibuffer prompt handler) is expected to own an instance of
// [CompletionModel] and drive it from TAB key events:
//
//   - first TAB: call `complete(input)`; if it returns a longer string
//     than `input`, replace the minibuffer text with it.
//   - second (and subsequent) TAB with the same prefix: call `cycle()`
//     to walk the ordered match list, one candidate per press, wrapping
//     around at the end — the classic Emacs "TAB TAB TAB..." cycle.
//   - any edit to the minibuffer text should call `resetCycle()` (or
//     just start a fresh `matches`/`complete` call, which implicitly
//     resets the cycle position) so cycling restarts from the new
//     prefix.

/// A pure, Flutter-free minibuffer completion model.
///
/// Mirrors Emacs `minibuffer-complete` / `minibuffer-complete-word`
/// semantics closely enough for editor use:
///
/// - [matches] returns candidates starting with the given prefix, in the
///   order they were supplied to the constructor.
/// - [complete] returns the longest string that is a common prefix of all
///   matching candidates (Emacs' "complete as far as unambiguous"
///   behavior). If there is exactly one match, that candidate is returned
///   in full. If there are no matches, the original prefix is returned
///   unchanged.
/// - [cycle] / [cycleNext] / [cyclePrevious] step through the ordered
///   match list for the last prefix passed to [matches] or [complete],
///   wrapping around at either end — this is what powers repeated-TAB
///   cycling through candidates.
class CompletionModel {
  CompletionModel(List<String> candidates, {this.caseInsensitive = false})
      : candidates = List<String>.unmodifiable(candidates);

  /// The full candidate set, in the order supplied.
  final List<String> candidates;

  /// When true, prefix matching and common-prefix computation ignore
  /// case. The candidates themselves are never case-folded in the
  /// returned strings — only the comparison is case-insensitive.
  final bool caseInsensitive;

  String? _cyclePrefix;
  List<String> _cycleMatches = const [];
  int _cycleIndex = -1;

  String _fold(String s) => caseInsensitive ? s.toLowerCase() : s;

  /// Ordered candidates whose text starts with [prefix].
  ///
  /// Order matches [candidates]' original order (stable filter), which is
  /// also the order [cycle] walks.
  List<String> matches(String prefix) {
    final needle = _fold(prefix);
    return candidates.where((c) => _fold(c).startsWith(needle)).toList();
  }

  /// Returns the longest common completion of [prefix] against
  /// [candidates]:
  ///
  /// - No matches: returns [prefix] unchanged.
  /// - Exactly one match: returns that candidate in full.
  /// - Multiple matches: returns the longest common prefix shared by all
  ///   of them (which may equal [prefix] itself if the matches diverge
  ///   immediately after it).
  ///
  /// Calling this resets the TAB-cycle position to the start of the new
  /// match list, mirroring Emacs (typing narrows/replaces the completion
  /// candidate set, restarting the cycle).
  String complete(String prefix) {
    final found = matches(prefix);
    _cyclePrefix = prefix;
    _cycleMatches = found;
    _cycleIndex = -1;

    if (found.isEmpty) return prefix;
    if (found.length == 1) return found.first;
    return _longestCommonPrefix(found, caseInsensitive: caseInsensitive);
  }

  /// Advances the TAB-cycle for the current match set (established by the
  /// last [complete] or [matches] call) and returns the next candidate,
  /// wrapping around to the first match after the last.
  ///
  /// Returns `null` if there is no active match set (i.e. [complete] /
  /// [matches] was never called, or returned zero matches).
  String? cycle() => cycleNext();

  /// Same as [cycle]; explicit forward-direction name.
  String? cycleNext() {
    if (_cycleMatches.isEmpty) return null;
    // -1 is the "not yet started" sentinel: the first forward step lands
    // on the first match (index 0).
    _cycleIndex =
        _cycleIndex == -1 ? 0 : (_cycleIndex + 1) % _cycleMatches.length;
    return _cycleMatches[_cycleIndex];
  }

  /// Steps the TAB-cycle backwards, wrapping around to the last match
  /// before the first. Returns `null` if there is no active match set.
  String? cyclePrevious() {
    if (_cycleMatches.isEmpty) return null;
    // -1 is the "not yet started" sentinel. A plain modular decrement
    // handles it uniformly (no special-casing needed): starting from -1,
    // the first backward step lands on `length - 2` — one further back
    // than the position cycleNext()'s first forward step would land on
    // (index 0) — which is the expected "TAB TAB" symmetric behavior.
    final length = _cycleMatches.length;
    _cycleIndex = ((_cycleIndex - 1) % length + length) % length;
    return _cycleMatches[_cycleIndex];
  }

  /// Explicitly resets cycle state, e.g. after the minibuffer text was
  /// edited by something other than a completion call.
  void resetCycle() {
    _cyclePrefix = null;
    _cycleMatches = const [];
    _cycleIndex = -1;
  }

  /// The prefix the current cycle/match set was computed against, or
  /// `null` if none is active.
  String? get activeCyclePrefix => _cyclePrefix;

  /// The ordered match list backing the current cycle, or an empty list
  /// if none is active.
  List<String> get cycleMatches => List<String>.unmodifiable(_cycleMatches);

  /// Longest common prefix of an EXPLICIT candidate set — for TAB completion
  /// whose provider already did its OWN (possibly fuzzy / ordered, non-prefix)
  /// matching, so the candidates need not share any literal prefix with the
  /// typed input. Running [complete] there would re-filter by literal prefix
  /// via [matches] and drop every fuzzy match; this bypasses that filter and
  /// returns the common head of the given candidates as-is. With
  /// [caseInsensitive] the comparison folds case but the result keeps the
  /// first candidate's original casing. Empty input -> `''`.
  static String longestCommonPrefixOf(
    List<String> candidates, {
    bool caseInsensitive = false,
  }) =>
      candidates.isEmpty
          ? ''
          : _longestCommonPrefix(candidates, caseInsensitive: caseInsensitive);

  static String _longestCommonPrefix(
    List<String> strings, {
    required bool caseInsensitive,
  }) {
    if (strings.isEmpty) return '';
    var prefix = strings.first;
    for (final s in strings.skip(1)) {
      prefix = _pairwiseCommonPrefix(
        prefix,
        s,
        caseInsensitive: caseInsensitive,
      );
      if (prefix.isEmpty) break;
    }
    return prefix;
  }

  static String _pairwiseCommonPrefix(
    String a,
    String b, {
    required bool caseInsensitive,
  }) {
    final fa = caseInsensitive ? a.toLowerCase() : a;
    final fb = caseInsensitive ? b.toLowerCase() : b;
    final len = fa.length < fb.length ? fa.length : fb.length;
    var i = 0;
    while (i < len && fa[i] == fb[i]) {
      i++;
    }
    // Return the prefix sliced from the original-cased `a` so callers get
    // back text matching a real candidate's casing, not the folded form.
    return a.substring(0, i);
  }
}
