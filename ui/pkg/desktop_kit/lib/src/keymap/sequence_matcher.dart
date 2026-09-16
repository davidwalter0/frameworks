// Data-driven multi-stroke key-sequence dispatcher.
//
// [SequenceMatcher] generalises the hardcoded [PrefixDispatcher] C-x state
// machine into a trie over [KeyChordSequence] bindings. Feed it [KeyChord]
// strokes one at a time via [feed]; it returns one of four [SequenceMatchResult]
// variants — idle, pending, matched, or cancelled — that the host widget uses
// to drive the editor's "pending prefix" minibuffer indicator and intent
// dispatch.
//
// ## Semantics (Emacs-compatible)
//
// * **Idle**: the stroke is not part of any bound sequence; the caller falls
//   through to normal [ShortcutActivator] handling.
// * **Pending**: the stroke arms a proper-prefix of one or more sequences; the
//   matcher waits for the next stroke.  [SequenceMatchPending.pendingLabel]
//   carries a minibuffer-ready string (e.g. `"Ctrl+X –"`).
// * **Matched**: the stroke completes a bound sequence.  Immediate-match
//   semantics (Emacs rule): if the same stroke *also* starts a longer sequence,
//   the shorter binding wins immediately — the caller never waits.  The longer
//   binding is effectively shadowed, which is exactly what step-1's
//   [ShadowConflict] detection warns about.
// * **Cancelled**: [cancel] was called, a cancel chord (C-g / Escape by default)
//   was fed while pending, or an unrecognised stroke arrived while pending.  The
//   [SequenceMatchCancelled] variant exposes the swallowed stroke so the caller
//   can flash an "undefined" message (Emacs style) or re-feed it as a fresh
//   single-stroke.
//
// ## Timeout (opt-in, Timer-free)
//
// The matcher is pure / testable: it owns no [Timer].  Pass a [Duration] as
// [timeout]; call [tick] with the current time after each "clock tick" in the
// host.  If pending and the elapsed time exceeds [timeout], [tick] transitions
// to cancelled and returns the [SequenceMatchResult].  The companion
// [SequenceMatcherBinding] mixin (below) wires a real [Timer] for widget use.
//
// ## Single-stroke sequences
//
// A single-stroke (length-1) sequence is NOT the matcher's responsibility: those
// live in the [ShortcutActivator] map and [Keymaps.forMode].  Feeding a chord
// that matches only a length-1 sequence returns [SequenceMatchResult.idle] so
// the caller continues to normal handling.  (A 1-stroke sequence can still be
// *stored* in the [SequenceMatcher] if you pass the full
// [KeymapConfig.bindingsFor] instead of just [sequenceBindings], but the
// behaviour is intentionally pass-through.)
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import 'key_chord.dart';
import 'key_chord_sequence.dart';
import 'keymap_registry.dart';

// ---------------------------------------------------------------------------
// Result sealed hierarchy
// ---------------------------------------------------------------------------

/// The four outcomes a [SequenceMatcher.feed] call can return.
///
/// Discriminate with [is SequenceMatchIdle] etc. or use `switch`.
sealed class SequenceMatchResult {
  const SequenceMatchResult();
}

/// The fed stroke is not part of any multi-stroke sequence.
///
/// The caller should fall through to normal [ShortcutActivator] handling.
/// This is the guaranteed response for single-stroke sequences — they belong
/// to the [ShortcutActivator] map, not the sequence matcher.
final class SequenceMatchIdle extends SequenceMatchResult {
  const SequenceMatchIdle();
  @override
  String toString() => 'SequenceMatchIdle()';
}

/// The matcher has consumed one or more strokes of a proper-prefix and is
/// waiting for the next stroke.
///
/// Display [pendingLabel] in the minibuffer (e.g. `"Ctrl+X –"`).
/// [pendingStrokes] is the ordered list of strokes consumed so far.
final class SequenceMatchPending extends SequenceMatchResult {
  const SequenceMatchPending({
    required this.pendingLabel,
    required this.pendingStrokes,
  });

  /// Minibuffer-ready label showing the consumed strokes, e.g. `"Ctrl+X –"`.
  final String pendingLabel;

  /// The strokes consumed so far (length >= 1).
  final List<KeyChord> pendingStrokes;

  @override
  String toString() =>
      'SequenceMatchPending(label: $pendingLabel, strokes: $pendingStrokes)';
}

/// The fed stroke completed a bound key sequence.
///
/// [intentId] is the registered intent id (resolve it via [KeymapRegistry]
/// or [resolveIntent]).  [sequence] is the full matched sequence.
///
/// **Immediate-match semantics (Emacs rule):** even if the same stroke also
/// begins a longer sequence, the shorter binding wins immediately.  The
/// shadowed longer binding is what step-1's [ShadowConflict] warns about.
final class SequenceMatchMatched extends SequenceMatchResult {
  const SequenceMatchMatched({
    required this.intentId,
    required this.sequence,
  });

  /// The registered intent id for the matched sequence.
  final String intentId;

  /// The full [KeyChordSequence] that was matched.
  final KeyChordSequence sequence;

  @override
  String toString() =>
      'SequenceMatchMatched(intentId: $intentId, sequence: $sequence)';
}

/// The pending sequence was cancelled — either explicitly (via [cancel] or a
/// cancel chord), or because a non-matching stroke arrived while pending.
///
/// [swallowedStroke] is the stroke that caused the cancellation (the
/// non-matching or explicit-cancel chord); it is `null` only when cancellation
/// came from an external [cancel()] call or a timeout.  The caller can use it
/// to flash an "undefined" message (Emacs: "C-x <key> is undefined") or to
/// re-feed the stroke as a fresh single-stroke attempt.
final class SequenceMatchCancelled extends SequenceMatchResult {
  const SequenceMatchCancelled({this.swallowedStroke});

  /// The stroke that triggered the cancellation, if any.
  final KeyChord? swallowedStroke;

  @override
  String toString() =>
      'SequenceMatchCancelled(swallowedStroke: $swallowedStroke)';
}

// ---------------------------------------------------------------------------
// Trie node (internal)
// ---------------------------------------------------------------------------

/// A node in the [_SequenceTrie] — covers one stroke position.
class _TrieNode {
  /// Child nodes keyed by the next [KeyChord] stroke.
  final Map<KeyChord, _TrieNode> children = <KeyChord, _TrieNode>{};

  /// If non-null, the sequence ending at this node is bound to this intent id.
  String? intentId;
}

/// A prefix trie over [KeyChordSequence] bindings.
class _SequenceTrie {
  final _TrieNode _root = _TrieNode();

  /// Insert a [sequence] → [intentId] mapping.  Only sequences with length > 1
  /// are inserted (single-stroke sequences belong to the ShortcutActivator map).
  void insert(KeyChordSequence sequence, String intentId) {
    if (sequence.isSingle) return;
    var node = _root;
    for (final chord in sequence.strokes) {
      node = node.children.putIfAbsent(chord, _TrieNode.new);
    }
    node.intentId = intentId;
  }

  /// Walk [strokes] down the trie from root, returning the node reached or
  /// `null` if the path does not exist.
  _TrieNode? walk(List<KeyChord> strokes) {
    var node = _root;
    for (final chord in strokes) {
      final next = node.children[chord];
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  /// Whether any sequence starts with [strokes].
  bool hasPrefix(List<KeyChord> strokes) => walk(strokes) != null;
}

// ---------------------------------------------------------------------------
// SequenceMatcher
// ---------------------------------------------------------------------------

/// Keyboard keys that cancel a pending prefix by default (C-g and Escape).
///
/// Callers may override via the [SequenceMatcher.cancelChords] constructor
/// parameter.
final Set<KeyChord> _defaultCancelChords = <KeyChord>{
  // C-g — keyboard-quit (Emacs).
  KeyChord(keyId: LogicalKeyboardKey.keyG.keyId, control: true),
  // Escape.
  KeyChord(keyId: LogicalKeyboardKey.escape.keyId),
};

/// A KeyEvent-level trie matcher over [KeyChordSequence] bindings.
///
/// Construct from [KeymapConfig.sequenceBindings] (length>1 bindings only) or
/// from a raw `Map<KeyChordSequence, String>`.  Feed [KeyChord] strokes via
/// [feed]; receive a [SequenceMatchResult] indicating idle / pending / matched
/// / cancelled.
///
/// The matcher is **pure and Timer-free** — it holds no [dart:async] state and
/// is fully unit-testable without a widget tree or an event loop.  For real UI
/// use, mix in [SequenceMatcherBinding] which owns the [Timer].
///
/// ### Disambiguation rule (Emacs)
///
/// When a stroke completes a sequence *and* is also a proper prefix of a longer
/// one, the shorter binding matches immediately.  Waiting for the next stroke
/// is never done — the "timer-based disambiguation" pattern that some apps use
/// is intentionally absent here.  This mirrors Emacs behaviour and is why
/// step-1's [ShadowConflict] detection matters: a shorter binding shadows
/// longer ones.
///
/// ### Single-stroke sequences
///
/// Feeding a chord that would match only a length-1 sequence returns
/// [SequenceMatchIdle].  Single-stroke sequences belong in the
/// [ShortcutActivator] map, not here.  Constructing a [SequenceMatcher] from
/// [KeymapConfig.bindingsFor] (which includes length-1 entries) is safe — they
/// are silently skipped by the trie.
class SequenceMatcher {
  /// Create a [SequenceMatcher] from a `sequence → intent-id` map.
  ///
  /// [bindings] is typically [KeymapConfig.sequenceBindings(mode)] (length>1
  /// sequences only), but you may also pass the full [KeymapConfig.bindingsFor]
  /// — length-1 entries are silently ignored.
  ///
  /// [cancelChords] defaults to C-g and Escape; supply a custom set to change
  /// which strokes abort a pending prefix.
  ///
  /// [timeout] is optional.  If given, [tick] transitions a pending sequence to
  /// [SequenceMatchCancelled] once [timeout] has elapsed.  The matcher owns no
  /// [Timer] — see [SequenceMatcherBinding] for the widget-side helper.
  SequenceMatcher(
    Map<KeyChordSequence, String> bindings, {
    Set<KeyChord>? cancelChords,
    this.timeout,
  }) : cancelChords = cancelChords ??
            Set<KeyChord>.unmodifiable(
              _defaultCancelChords,
            ) {
    for (final entry in bindings.entries) {
      _trie.insert(entry.key, entry.value);
    }
  }

  /// The set of chords that cancel a pending prefix.  Defaults to C-g and
  /// Escape.
  final Set<KeyChord> cancelChords;

  /// Optional timeout for a pending prefix.  When non-null, call [tick] with
  /// the current [DateTime] to drive expiry.  The matcher owns no [Timer].
  final Duration? timeout;

  final _SequenceTrie _trie = _SequenceTrie();
  final List<KeyChord> _pending = <KeyChord>[];
  DateTime? _pendingStart;

  // --- public state -----------------------------------------------------------

  /// Whether a prefix is currently armed (one or more strokes consumed, waiting
  /// for the next).
  bool get isPending => _pending.isNotEmpty;

  /// The strokes consumed so far.  Empty when not pending.
  List<KeyChord> get pendingStrokes => List<KeyChord>.unmodifiable(_pending);

  // --- core API ---------------------------------------------------------------

  /// Feed a [KeyChord] stroke to the matcher and return the result.
  ///
  /// * [SequenceMatchIdle] — the stroke is not part of any multi-stroke
  ///   sequence; caller handles it normally.
  /// * [SequenceMatchPending] — the stroke arms or extends a proper prefix;
  ///   display [SequenceMatchPending.pendingLabel] in the minibuffer.
  /// * [SequenceMatchMatched] — the stroke completed a bound sequence; fire
  ///   the [SequenceMatchMatched.intentId].
  /// * [SequenceMatchCancelled] — the stroke cancelled a pending prefix (cancel
  ///   chord or unrecognised while pending); the swallowed stroke is exposed.
  SequenceMatchResult feed(KeyChord stroke) {
    // --- cancel chord while pending -------------------------------------------
    if (_pending.isNotEmpty && cancelChords.contains(stroke)) {
      _reset();
      return const SequenceMatchCancelled();
    }

    // --- extend the pending prefix or start a new one -------------------------
    final next = List<KeyChord>.of(_pending)..add(stroke);
    final node = _trie.walk(next);

    if (node == null) {
      // The stroke does not extend any known sequence path.
      if (_pending.isEmpty) {
        // Not pending — this stroke is simply not part of any sequence.
        return const SequenceMatchIdle();
      } else {
        // Was pending — the new stroke is undefined in this prefix context.
        _reset();
        return SequenceMatchCancelled(swallowedStroke: stroke);
      }
    }

    // The path exists in the trie.  Check for a match at this depth.
    final intentId = node.intentId;
    if (intentId != null) {
      // Immediate-match (Emacs rule): even if this node also has children,
      // we match now.  The longer shadowed bindings are flagged by ShadowConflict.
      final sequence = KeyChordSequence(next);
      _reset();
      return SequenceMatchMatched(intentId: intentId, sequence: sequence);
    }

    // No terminal at this depth but children exist — arm/extend the prefix.
    _pending
      ..clear()
      ..addAll(next);
    _pendingStart ??= DateTime.now();
    final label = _pendingLabel(next);
    return SequenceMatchPending(
      pendingLabel: label,
      pendingStrokes: List<KeyChord>.unmodifiable(next),
    );
  }

  /// Check whether a pending prefix has timed out.
  ///
  /// Call this method from a periodic Timer (or any clock source) passing the
  /// current [DateTime].  If [timeout] is set and a prefix has been pending
  /// longer than [timeout], the pending state is cleared and
  /// [SequenceMatchCancelled] is returned.  Returns `null` if no timeout has
  /// occurred (either not pending, no [timeout] set, or not yet expired).
  SequenceMatchCancelled? tick(DateTime now) {
    if (!isPending) return null;
    final d = timeout;
    if (d == null) return null;
    final start = _pendingStart;
    if (start == null) return null;
    if (now.difference(start) >= d) {
      _reset();
      return const SequenceMatchCancelled();
    }
    return null;
  }

  /// Cancel the current pending prefix, if any, and return to idle.
  ///
  /// Returns [SequenceMatchCancelled] with no swallowed stroke.  Has no effect
  /// and returns `null` if not pending.
  SequenceMatchCancelled? cancel() {
    if (!isPending) return null;
    _reset();
    return const SequenceMatchCancelled();
  }

  /// Reset to idle state unconditionally.
  void reset() => _reset();

  // --- helpers ---------------------------------------------------------------

  void _reset() {
    _pending.clear();
    _pendingStart = null;
  }

  /// Build a minibuffer label from the pending [strokes].
  ///
  /// Produces e.g. `"Ctrl+X –"` for a single-stroke prefix or
  /// `"Ctrl+X Ctrl+C –"` for a two-stroke prefix.
  static String _pendingLabel(List<KeyChord> strokes) {
    final parts = strokes.map((c) => c.label).join(' ');
    return '$parts –';
  }
}

// ---------------------------------------------------------------------------
// Registry integration helper
// ---------------------------------------------------------------------------

/// Resolve a matched intent id to an [Intent] via [registry].
///
/// This mirrors [KeymapConfig.toKeymap]'s id→[Intent] resolution so apps can
/// fire the same [Intent] objects for both single-stroke and multi-stroke
/// bindings.  Returns `null` if [id] is not registered.
///
/// ```dart
/// final result = matcher.feed(chord);
/// if (result is SequenceMatchMatched) {
///   final intent = resolveIntent(result.intentId, registry);
///   if (intent != null) Actions.invoke(context, intent);
/// }
/// ```
Intent? resolveIntent(String id, KeymapRegistry registry) =>
    registry.intentFor(id);

// ---------------------------------------------------------------------------
// SequenceMatcherBinding — widget-side Timer helper
// ---------------------------------------------------------------------------

/// A [State] mixin that owns a real [Timer] for [SequenceMatcher.timeout].
///
/// Mix this into a [State] that owns a [SequenceMatcher] with a [timeout] set.
/// Override [onSequenceResult] to handle [SequenceMatchResult]s (called both
/// from [feedFromMatcher] and from the internal timeout tick).
///
/// ```dart
/// class _MyState extends State<MyWidget>
///     with SequenceMatcherBinding {
///   @override
///   SequenceMatcher get matcher => _matcher;
///
///   @override
///   void onSequenceResult(SequenceMatchResult result) {
///     // update UI / fire intents
///   }
/// }
/// ```
mixin SequenceMatcherBinding<T extends StatefulWidget> on State<T> {
  /// The [SequenceMatcher] this binding drives.  Must be non-null when [mounted].
  SequenceMatcher get matcher;

  /// Monotonically-incrementing generation counter.  Each time we schedule a
  /// new timeout we bump this; the pending [Future] captures the value and does
  /// nothing if it sees a stale generation when it fires.  This avoids needing
  /// a [dart:async] [Timer] (which would require another import).
  int _timeoutGeneration = 0;

  @override
  void dispose() {
    // Bump the generation so any in-flight Future becomes a no-op.
    _timeoutGeneration++;
    super.dispose();
  }

  /// Feed a [KeyChord] stroke through [matcher] and dispatch the result to
  /// [onSequenceResult].  Starts or restarts the internal timeout when the
  /// result is [SequenceMatchPending] and [matcher.timeout] is set.
  void feedFromMatcher(KeyChord chord) {
    final result = matcher.feed(chord);
    _rescheduleTimeout(result);
    onSequenceResult(result);
  }

  /// Called with the [SequenceMatchResult] from every feed (and from a timeout
  /// expiry).  Subclass implements: update minibuffer, fire intents, etc.
  void onSequenceResult(SequenceMatchResult result);

  void _rescheduleTimeout(SequenceMatchResult result) {
    // Invalidate any prior pending Future.
    _timeoutGeneration++;
    final d = matcher.timeout;
    if (d == null) return;
    if (result is! SequenceMatchPending) return;

    final generation = _timeoutGeneration;
    Future<void>.delayed(d, () {
      if (!mounted) return;
      if (_timeoutGeneration != generation) return; // superseded
      final cancelled = matcher.tick(DateTime.now());
      if (cancelled != null) {
        onSequenceResult(cancelled);
        setState(() {});
      }
    });
  }
}
