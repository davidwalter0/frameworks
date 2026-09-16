// Serialisable multi-stroke key sequence for the keymap editor.
//
// A [KeyChordSequence] is an ordered list of one or more [KeyChord] strokes —
// the serialisable analogue of an Emacs *key sequence* such as `C-x C-s`. A
// single keystroke is simply a length-1 sequence, which is what keeps this
// change backward compatible: the sequence [token] of a one-stroke sequence is
// byte-identical to the old bare [KeyChord.token], so persisted configs written
// before sequences existed still parse (each bare chord token becomes a
// length-1 sequence) and re-encode unchanged.
//
// Flutter's [Shortcuts]/[ShortcutActivator] machinery cannot express a
// multi-stroke sequence (there is no "then" combinator), so only length-1
// sequences round-trip to a [ShortcutActivator]; longer sequences are dispatched
// by the prefix state machine instead (see [PrefixDispatcher]; the runtime
// matcher that consumes multi-stroke bindings arrives in a later step). The
// prefix helpers here ([isPrefixOf] / [startsWith]) are what that matcher and
// the editor's shadowing-conflict detection are built on.
library;

import 'package:flutter/widgets.dart';

import 'key_chord.dart';

/// The separator between strokes in a [KeyChordSequence.token]: a single space,
/// so `[C-x, C-s]` serialises to `"C-208 C-115"`. A lone [KeyChord.token]
/// contains no spaces, so a bare token parses back as a length-1 sequence.
const String _kStrokeSeparator = ' ';

/// An ordered, non-empty list of [KeyChord] strokes — the serialisable form of
/// an Emacs key *sequence* like `C-x C-s`.
///
/// A single keystroke is a length-1 sequence; that is the common case and the
/// backward-compatible one (see the library doc). Equality and [hashCode] are by
/// value over the strokes in order, so a [KeyChordSequence] is a well-behaved
/// [Map] key. [token] is the canonical string form (space-joined stroke tokens)
/// used as a JSON object key; [label] is a human-readable display string
/// ("C-x C-s"-style, using each stroke's [KeyChord.label] joined by spaces).
@immutable
class KeyChordSequence {
  /// Create a sequence from one or more [strokes]. Throws [ArgumentError] if
  /// [strokes] is empty — a sequence must have at least one chord.
  KeyChordSequence(List<KeyChord> strokes)
      : strokes = List<KeyChord>.unmodifiable(strokes) {
    if (this.strokes.isEmpty) {
      throw ArgumentError.value(
        strokes,
        'strokes',
        'a KeyChordSequence must contain at least one KeyChord',
      );
    }
  }

  /// Convenience constructor for the common length-1 case: wrap a single
  /// [chord] as a sequence. `KeyChordSequence.single(c).token == c.token`.
  KeyChordSequence.single(KeyChord chord)
      : strokes = List<KeyChord>.unmodifiable(<KeyChord>[chord]);

  /// Parse a [token] produced by [token]: one or more [KeyChord.token]s joined
  /// by whitespace (`"C-208 C-115"`). Splits on any run of whitespace and parses
  /// each piece with [KeyChord.parse]. A token with no whitespace yields a
  /// length-1 sequence — this is what lets a pre-sequence config (bare chord
  /// tokens) load unchanged. Throws [FormatException] on an empty token or if
  /// any stroke is malformed.
  factory KeyChordSequence.parse(String token) {
    final pieces = token
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (pieces.isEmpty) {
      throw FormatException('empty key-sequence token', token);
    }
    return KeyChordSequence(
      <KeyChord>[for (final p in pieces) KeyChord.parse(p)],
    );
  }

  /// The strokes, in order. Unmodifiable; length is always >= 1.
  final List<KeyChord> strokes;

  /// The number of strokes (>= 1).
  int get length => strokes.length;

  /// Whether this is a single-keystroke sequence (the common, Flutter-
  /// [ShortcutActivator]-expressible case).
  bool get isSingle => strokes.length == 1;

  /// The first stroke — the "prefix" stroke of a multi-stroke sequence (e.g.
  /// the `C-x` of `C-x C-s`).
  KeyChord get first => strokes.first;

  /// The last stroke.
  KeyChord get last => strokes.last;

  /// The single stroke, iff this is a length-1 sequence; otherwise `null`.
  /// Handy at the boundary with the one-stroke-only [ShortcutActivator] world.
  KeyChord? get asSingle => isSingle ? strokes.first : null;

  /// Canonical string form used as a JSON object key: each stroke's
  /// [KeyChord.token] joined by a single space. For a length-1 sequence this is
  /// exactly the stroke's own token (no separator), giving byte-stable
  /// round-tripping of pre-sequence configs. Inverse of [KeyChordSequence.parse].
  String get token => strokes.map((c) => c.token).join(_kStrokeSeparator);

  /// Human-readable label: each stroke's [KeyChord.label] joined by spaces, e.g.
  /// `"Ctrl+X Ctrl+S"`. (Emacs `C-x C-s` notation is the terser display used in
  /// the help dialog; this uses the same `Ctrl+`… vocabulary as [KeyChord.label]
  /// for consistency with single-chord chips.)
  String get label => strokes.map((c) => c.label).join(_kStrokeSeparator);

  /// Whether [other] begins with this entire sequence — i.e. this sequence is a
  /// (not-necessarily-proper) prefix of [other]. `[C-x].isPrefixOf([C-x, C-s])`
  /// is true; `[C-x, C-s].isPrefixOf([C-x])` is false; a sequence is a prefix of
  /// itself. Used by shadow-conflict detection and (in a later step) the
  /// multi-stroke runtime matcher.
  bool isPrefixOf(KeyChordSequence other) {
    if (strokes.length > other.strokes.length) return false;
    for (var i = 0; i < strokes.length; i++) {
      if (strokes[i] != other.strokes[i]) return false;
    }
    return true;
  }

  /// Whether this sequence begins with the whole of [other] — the dual of
  /// [isPrefixOf] (`a.startsWith(b)` == `b.isPrefixOf(a)`). Reads naturally when
  /// asking "does the sequence the user is typing start with a known prefix?".
  bool startsWith(KeyChordSequence other) => other.isPrefixOf(this);

  /// Whether this is a *proper* prefix of [other]: a prefix and strictly shorter
  /// (so equal sequences are not proper prefixes of each other). This is the
  /// relation that constitutes a shadow — a binding on `C-x` properly prefixes a
  /// binding on `C-x C-s`, hiding the latter. See [findShadowConflicts].
  bool isProperPrefixOf(KeyChordSequence other) =>
      strokes.length < other.strokes.length && isPrefixOf(other);

  /// A copy with [chord] appended as a new final stroke (used by the capture
  /// dialog as the user builds up a multi-stroke sequence).
  KeyChordSequence append(KeyChord chord) =>
      KeyChordSequence(<KeyChord>[...strokes, chord]);

  /// A copy with the last stroke removed, or `null` if that would empty the
  /// sequence (a sequence must keep >= 1 stroke). Used by the capture dialog's
  /// Backspace handling.
  KeyChordSequence? dropLast() => strokes.length <= 1
      ? null
      : KeyChordSequence(strokes.sublist(0, strokes.length - 1));

  @override
  bool operator ==(Object other) {
    if (other is! KeyChordSequence) return false;
    if (other.strokes.length != strokes.length) return false;
    for (var i = 0; i < strokes.length; i++) {
      if (other.strokes[i] != strokes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(strokes);

  @override
  String toString() => 'KeyChordSequence($label)';
}

/// A shadowing conflict: [prefix] is a proper prefix of [shadowed], so a binding
/// on [prefix] fires before the user can complete [shadowed]. Both sequences are
/// bound in the same mode; the editor flags both rows.
@immutable
class ShadowConflict {
  /// Create a [ShadowConflict].
  const ShadowConflict({required this.prefix, required this.shadowed});

  /// The shorter binding that fires first, hiding [shadowed].
  final KeyChordSequence prefix;

  /// The longer binding that can never be reached because [prefix] intercepts
  /// its opening strokes.
  final KeyChordSequence shadowed;

  @override
  bool operator ==(Object other) =>
      other is ShadowConflict &&
      other.prefix == prefix &&
      other.shadowed == shadowed;

  @override
  int get hashCode => Object.hash(prefix, shadowed);

  @override
  String toString() =>
      'ShadowConflict(${prefix.token} shadows ${shadowed.token})';
}

/// Find every shadowing conflict among [sequences] (the bound key sequences of a
/// single mode): each pair where one sequence is a *proper prefix* of another.
///
/// Non-blocking by design — the editor uses this only to warn. Returned in a
/// stable order (by prefix token, then shadowed token) so the UI and tests see a
/// deterministic list. A single-chord-only keymap (every sequence length 1) can
/// never produce a conflict, so the common case returns empty cheaply.
List<ShadowConflict> findShadowConflicts(Iterable<KeyChordSequence> sequences) {
  final list = sequences.toList(growable: false);
  final out = <ShadowConflict>[];
  for (var i = 0; i < list.length; i++) {
    for (var j = 0; j < list.length; j++) {
      if (i == j) continue;
      if (list[i].isProperPrefixOf(list[j])) {
        out.add(ShadowConflict(prefix: list[i], shadowed: list[j]));
      }
    }
  }
  out.sort((a, b) {
    final byPrefix = a.prefix.token.compareTo(b.prefix.token);
    if (byPrefix != 0) return byPrefix;
    return a.shadowed.token.compareTo(b.shadowed.token);
  });
  return out;
}

/// The set of sequences from [sequences] that participate in *any* shadow
/// conflict — either as a prefix that shadows, or as a sequence being shadowed.
/// This is the convenient form the editor needs: "does this row get a warning
/// icon?". Built from [findShadowConflicts].
Set<KeyChordSequence> shadowedSequences(
  Iterable<KeyChordSequence> sequences,
) {
  final out = <KeyChordSequence>{};
  for (final c in findShadowConflicts(sequences)) {
    out
      ..add(c.prefix)
      ..add(c.shadowed);
  }
  return out;
}
