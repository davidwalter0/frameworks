// An Emacs-style kill ring: a bounded ring buffer of killed text with a
// yank pointer that yank-pop (M-y) rotates through.
//
// Ported verbatim from voicelab / notekeep. Pure and headlessly testable —
// no Flutter, no controllers. The editor glue calls [kill]/[killAppend]/[copy]
// when text is removed/copied, and [yank]/[yankPop] when reinserting.
//
// Append-merge semantics (Emacs): consecutive kills with no intervening
// non-kill command coalesce into a single ring entry. The caller signals
// "the previous command was also a kill" by calling [killAppend] (append to
// the front entry) vs. [kill] (push a fresh entry).
library;

/// An Emacs-style kill ring with append-merge, yank, and yank-pop semantics.
class KillRing {
  // Keep the public `maxEntries` name (a private-named initializing formal is
  // not allowed).
  // ignore: prefer_initializing_formals
  KillRing({int maxEntries = 60}) : _maxEntries = maxEntries;

  final int _maxEntries;
  final List<String> _entries = <String>[];

  /// Index into [_entries] of the entry a [yank] would insert. 0 = most
  /// recent. Advanced by [yankPop].
  int _yankPointer = 0;

  /// Whether the immediately preceding ring operation was a kill — used to
  /// decide append-merge. The editor sets this via [kill]/[killAppend]; any
  /// non-kill editor command should call [breakKillSequence].
  bool _lastWasKill = false;

  /// True only right after a [yank]/[yankPop], so [yankPop] knows it may
  /// rotate (M-y is only valid immediately after a yank).
  bool _justYanked = false;

  /// Unmodifiable view of the ring entries (index 0 = most recent).
  List<String> get entries => List.unmodifiable(_entries);

  /// Current yank-pointer position.
  int get yankPointer => _yankPointer;

  /// True when the ring is empty.
  bool get isEmpty => _entries.isEmpty;

  /// Number of entries currently in the ring.
  int get length => _entries.length;

  /// The text the next [yank] would insert, or null if the ring is empty.
  String? get current => _entries.isEmpty ? null : _entries[_yankPointer];

  /// Whether the previous operation was a kill (drives append-merge). Exposed
  /// for the editor glue and tests.
  bool get lastWasKill => _lastWasKill;

  /// Whether a [yankPop] is currently valid (immediately after a yank).
  bool get canYankPop => _justYanked && _entries.isNotEmpty;

  /// Push [text] as a new most-recent kill entry. Resets the yank pointer.
  /// No-op for empty strings (Emacs never rings empty kills).
  void kill(String text) {
    if (text.isEmpty) {
      _lastWasKill = true;
      _justYanked = false;
      return;
    }
    _entries.insert(0, text);
    _trim();
    _yankPointer = 0;
    _lastWasKill = true;
    _justYanked = false;
  }

  /// Kill that respects append-merge: if the previous command was also a kill,
  /// merge [text] into the front entry (forward kill → append to end, backward
  /// kill → prepend). Otherwise behaves like [kill].
  ///
  /// [prepend] true models a backward kill (e.g. backward-kill-word) that
  /// grows the entry at the front.
  void killAppend(String text, {bool prepend = false}) {
    if (text.isEmpty) {
      _lastWasKill = true;
      _justYanked = false;
      return;
    }
    if (_lastWasKill && _entries.isNotEmpty) {
      _entries[0] = prepend ? '$text${_entries[0]}' : '${_entries[0]}$text';
      _yankPointer = 0;
      _lastWasKill = true;
      _justYanked = false;
      return;
    }
    kill(text);
  }

  /// Copy [text] into the ring (M-w / copy-region). Like [kill] but the caller
  /// has not removed anything from the buffer. Counts as a kill for
  /// append-merge bookkeeping (matches Emacs: a copy seeds the front entry).
  void copy(String text) => kill(text);

  /// Insert the current entry (C-y). Returns the inserted text (empty string
  /// if the ring is empty). Sets the "just yanked" flag so [yankPop] is
  /// permitted.
  String yank() {
    _lastWasKill = false;
    if (_entries.isEmpty) {
      _justYanked = false;
      return '';
    }
    _justYanked = true;
    return _entries[_yankPointer];
  }

  /// Rotate the yank pointer to the next-older entry and return its text
  /// (M-y). Only valid immediately after a [yank]/[yankPop]; otherwise
  /// returns null so the caller can signal an error ("Previous command was
  /// not a yank"). The editor is responsible for replacing the just-yanked
  /// region with the returned text.
  String? yankPop() {
    if (!_justYanked || _entries.isEmpty) return null;
    _yankPointer = (_yankPointer + 1) % _entries.length;
    _justYanked = true;
    _lastWasKill = false;
    return _entries[_yankPointer];
  }

  /// Mark the end of a kill sequence (any non-kill, non-yank editor command).
  /// The next [killAppend] then pushes a fresh entry instead of merging.
  void breakKillSequence() {
    _lastWasKill = false;
    _justYanked = false;
  }

  /// Point the yank pointer directly at ring position [index] (0 = most
  /// recent), e.g. from a kill-ring browser where the user picked which
  /// entry the next [yank] should insert (browse-kill-ring /
  /// counsel-yank-pop "set current" behaviour). Out-of-range [index] is
  /// ignored — a caller driving this from a UI snapshot may compute an index
  /// that has since fallen out of range (the ring shrank), and silently
  /// doing nothing is safer than clamping to a DIFFERENT entry the caller
  /// didn't ask for.
  ///
  /// Selecting an entry is neither a kill nor a yank, so [lastWasKill] and
  /// [canYankPop] are left exactly as they were.
  void setYankPointer(int index) {
    if (index < 0 || index >= _entries.length) return;
    _yankPointer = index;
  }

  /// Remove the entry at ring position [index] (0 = most recent), e.g. from
  /// a kill-ring browser's tag-for-deletion-then-execute flow. Out-of-range
  /// [index] is ignored (same reasoning as [setYankPointer]).
  ///
  /// The yank pointer is kept aimed at the SAME logical entry where one
  /// still exists: removing an entry before it shifts it back by one;
  /// removing the pointed-at entry itself (or removing past the new end)
  /// clamps into the remaining range.
  ///
  /// Callers removing MULTIPLE entries from one snapshot (e.g. several
  /// delete-tagged rows in a browser) MUST call this with indices in
  /// DESCENDING order. Removing a lower index first would shift every
  /// higher index down by one, invalidating the remaining targets; removing
  /// highest-to-lowest never does, because removing index i only ever
  /// shifts indices > i, all of which have already been processed.
  void removeAt(int index) {
    if (index < 0 || index >= _entries.length) return;
    _entries.removeAt(index);
    if (_entries.isEmpty) {
      _yankPointer = 0;
    } else if (index < _yankPointer) {
      _yankPointer -= 1;
    } else if (_yankPointer >= _entries.length) {
      _yankPointer = _entries.length - 1;
    }
  }

  /// Reset the ring to the empty state.
  void clear() {
    _entries.clear();
    _yankPointer = 0;
    _lastWasKill = false;
    _justYanked = false;
  }

  void _trim() {
    while (_entries.length > _maxEntries) {
      _entries.removeLast();
    }
    if (_yankPointer >= _entries.length) {
      _yankPointer = _entries.isEmpty ? 0 : _entries.length - 1;
    }
  }
}
