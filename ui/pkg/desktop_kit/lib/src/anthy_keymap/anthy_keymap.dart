// Shared Anthy IME keybinding tooling — the bridge between the kit's kana→kanji
// IME driver ([ImeController]) and its keymap engine.
//
// Sibling of `kana_keymap.dart`, but for the STATEFUL kana→kanji conversion
// flow rather than pure script conversion. Every app that offers Anthy input
// wants the same conversion commands bound the same way — convert / cycle
// candidates / commit / cancel / IME-backspace — so this module owns that
// pattern once instead of each app re-declaring the Intents, the bindings, and
// the controller-dispatch switch.
//
// TWO THINGS MAKE THIS DIFFERENT FROM kana_keymap:
//
//   1. **Context-scoped, not global.** These chords (Space, Enter, Esc,
//      Backspace, Shift+Space) only mean "convert / commit / cancel …" WHILE the
//      IME is composing or converting ([ImeState.isActive]). They are NOT merged
//      into the editor keymap — that would hijack the space bar and Enter for
//      ordinary typing. An app matches an incoming chord against
//      [anthyDefaultBindings] (or a user-rebound [anthyDefaultConfig]) ONLY when
//      the controller is active, and falls back to the editor keymap otherwise.
//
//   2. **Stateful dispatch, not a pure transform.** kana_keymap's
//      `kanaTransform` is `String -> String`; here the effect is a transition on
//      a live [ImeController] backed by an Anthy subprocess. [dispatchAnthyIntent]
//      drives the controller and returns an [AnthyDispatchResult] telling the app
//      what to do with the editor buffer (insert committed kanji / restore raw
//      kana / just repaint the active region).
//
// LAYERING: depends on BOTH `desktop_kit_anthy.dart` ([ImeController]) and
// `desktop_kit_keymap.dart`. A SEPARATE, opt-in entrypoint — not re-exported
// from the main barrel, so the core keymap stays IME-free and non-IME apps pull
// in nothing. Linux-oriented, like the Anthy driver itself.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../anthy/ime_controller.dart';
import '../anthy/preedit_session.dart';
import '../keymap/key_chord.dart';
import '../keymap/key_chord_sequence.dart';
import '../keymap/keymap_config.dart';
import '../keymap/keymap_mode.dart';
import '../keymap/keymap_registry.dart';

// --- Stable intent ids (persisted in KeymapConfig JSON — do not rename) -------

/// Space: convert the preedit, or advance to the next candidate. See
/// [ImeController.space].
const String kConvertOrNextCandidateId = 'imeConvertOrNext';

/// Shift+Space: cycle to the previous candidate. See [ImeController.shiftSpace].
const String kPreviousCandidateId = 'imePrevCandidate';

/// Enter: commit the conversion (Anthy learns). See [ImeController.commit].
const String kCommitConversionId = 'imeCommit';

/// Esc: cancel and revert to the raw hiragana. See [ImeController.cancel].
const String kCancelConversionId = 'imeCancel';

/// Backspace: revert converting→composing, or delete the last preedit char. See
/// [ImeController.backspace].
const String kImeBackspaceId = 'imeBackspace';

/// Right: move the active-segment cursor to the next segment. See
/// [ImeController.moveSegmentNext].
const String kMoveSegmentNextId = 'imeMoveSegmentNext';

/// Left: move the active-segment cursor to the previous segment. See
/// [ImeController.moveSegmentPrevious].
const String kMoveSegmentPreviousId = 'imeMoveSegmentPrevious';

/// Shift+Left: shrink the active segment. See [ImeController.shrinkSegment].
const String kShrinkSegmentId = 'imeShrinkSegment';

/// Shift+Right: grow the active segment. See [ImeController.growSegment].
const String kGrowSegmentId = 'imeGrowSegment';

/// Shift+K: flip the kana script (hiragana⇄katakana) of the live preedit —
/// composing OR converting — in place. See [ImeController.toggleScript].
///
/// A SEPARATE id from [kToggleKanaId] (whole-buffer, committed-text re-scripting
/// in `kana_keymap.dart`): this one acts only on the active preedit and keeps
/// the conversion group alive. Collapsing the two is the word-bank bug this
/// wiring exists to avoid.
const String kToggleScriptId = 'imeToggleScript';

/// Every Anthy IME intent id, for routing checks ([isAnthyIntentId]).
const Set<String> kAnthyIntentIds = <String>{
  kConvertOrNextCandidateId,
  kPreviousCandidateId,
  kCommitConversionId,
  kCancelConversionId,
  kImeBackspaceId,
  kMoveSegmentNextId,
  kMoveSegmentPreviousId,
  kShrinkSegmentId,
  kGrowSegmentId,
  kToggleScriptId,
};

/// Whether [id] is one of the Anthy IME intents (so the app routes it to
/// [dispatchAnthyIntent] rather than its editor actions).
bool isAnthyIntentId(String id) => kAnthyIntentIds.contains(id);

// --- Marker intents -----------------------------------------------------------

/// Convert the preedit to kanji, or advance to the next candidate.
class ConvertOrNextCandidateIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ConvertOrNextCandidateIntent();
}

/// Cycle to the previous candidate for the active segment.
class PreviousCandidateIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const PreviousCandidateIntent();
}

/// Commit the current conversion.
class CommitConversionIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const CommitConversionIntent();
}

/// Cancel the current conversion, reverting to the raw hiragana.
class CancelConversionIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const CancelConversionIntent();
}

/// Backspace within the IME (revert converting→composing, or delete a char).
class ImeBackspaceIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ImeBackspaceIntent();
}

/// Move the active-segment cursor to the next (right) segment.
class MoveSegmentNextIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const MoveSegmentNextIntent();
}

/// Move the active-segment cursor to the previous (left) segment.
class MoveSegmentPreviousIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const MoveSegmentPreviousIntent();
}

/// Shrink the active segment by one bunsetsu unit.
class ShrinkSegmentIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ShrinkSegmentIntent();
}

/// Grow the active segment by one bunsetsu unit.
class GrowSegmentIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const GrowSegmentIntent();
}

/// Flip the kana script of the live preedit (hiragana⇄katakana), in place.
class ToggleScriptIntent extends Intent {
  /// Const so it can seed a [KeymapAction.factory].
  const ToggleScriptIntent();
}

// --- Registry actions ---------------------------------------------------------

/// The bindable Anthy IME actions, in editor display order. Register with
/// [registerAnthyActions] so an editor can offer them (typically in a SEPARATE
/// IME keymap surface, not mixed into the ordinary editor keymap).
const List<KeymapAction> anthyKeymapActions = <KeymapAction>[
  KeymapAction(
    id: kConvertOrNextCandidateId,
    label: 'Convert / next candidate',
    group: 'IME (Anthy)',
    factory: ConvertOrNextCandidateIntent.new,
  ),
  KeymapAction(
    id: kPreviousCandidateId,
    label: 'Previous candidate',
    group: 'IME (Anthy)',
    factory: PreviousCandidateIntent.new,
  ),
  KeymapAction(
    id: kCommitConversionId,
    label: 'Commit conversion',
    group: 'IME (Anthy)',
    factory: CommitConversionIntent.new,
  ),
  KeymapAction(
    id: kCancelConversionId,
    label: 'Cancel conversion',
    group: 'IME (Anthy)',
    factory: CancelConversionIntent.new,
  ),
  KeymapAction(
    id: kImeBackspaceId,
    label: 'IME backspace',
    group: 'IME (Anthy)',
    factory: ImeBackspaceIntent.new,
  ),
  KeymapAction(
    id: kMoveSegmentNextId,
    label: 'Next segment',
    group: 'IME (Anthy)',
    factory: MoveSegmentNextIntent.new,
  ),
  KeymapAction(
    id: kMoveSegmentPreviousId,
    label: 'Previous segment',
    group: 'IME (Anthy)',
    factory: MoveSegmentPreviousIntent.new,
  ),
  KeymapAction(
    id: kShrinkSegmentId,
    label: 'Shrink segment',
    group: 'IME (Anthy)',
    factory: ShrinkSegmentIntent.new,
  ),
  KeymapAction(
    id: kGrowSegmentId,
    label: 'Grow segment',
    group: 'IME (Anthy)',
    factory: GrowSegmentIntent.new,
  ),
  KeymapAction(
    id: kToggleScriptId,
    label: 'Toggle kana script',
    group: 'IME (Anthy)',
    factory: ToggleScriptIntent.new,
  ),
];

/// Register every [anthyKeymapActions] entry into [registry].
void registerAnthyActions(KeymapRegistry registry) {
  for (final KeymapAction action in anthyKeymapActions) {
    registry.register(action);
  }
}

// --- Default (IME-active) bindings --------------------------------------------

KeyChord _chord(LogicalKeyboardKey key, {bool shift = false}) =>
    KeyChord(keyId: key.keyId, shift: shift);

/// The default IME-active keybindings — the emacs-anthy / egg convention:
/// Space→convert/next, Shift+Space→previous, Enter→commit, Esc→cancel,
/// Backspace→IME-backspace.
///
/// These belong to the IME context ONLY (matched while [ImeState.isActive]);
/// never merge them into the editor keymap — see the library doc.
Map<KeyChordSequence, String> anthyDefaultBindings() =>
    <KeyChordSequence, String>{
      KeyChordSequence.single(_chord(LogicalKeyboardKey.space)):
          kConvertOrNextCandidateId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.space, shift: true)):
          kPreviousCandidateId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.enter)):
          kCommitConversionId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.escape)):
          kCancelConversionId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.backspace)):
          kImeBackspaceId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.arrowRight)):
          kMoveSegmentNextId,
      KeyChordSequence.single(_chord(LogicalKeyboardKey.arrowLeft)):
          kMoveSegmentPreviousId,
      KeyChordSequence.single(
        _chord(LogicalKeyboardKey.arrowLeft, shift: true),
      ): kShrinkSegmentId,
      KeyChordSequence.single(
        _chord(LogicalKeyboardKey.arrowRight, shift: true),
      ): kGrowSegmentId,
      // Shift+K — script flip over the live preedit. Intercepted while the IME
      // is active, so it never reaches romaji input as a literal 'K'.
      KeyChordSequence.single(
        _chord(LogicalKeyboardKey.keyK, shift: true),
      ): kToggleScriptId,
    };

/// The IME bindings as a standalone [KeymapConfig] (same map under every mode),
/// for apps that let users rebind IME keys through a [KeymapEditor] in a
/// dedicated IME keymap surface. This is a SEPARATE config from the editor
/// keymap — do not merge the two.
KeymapConfig anthyDefaultConfig() {
  final Map<KeyChordSequence, String> bindings = anthyDefaultBindings();
  return KeymapConfig(<KeymapMode, Map<KeyChordSequence, String>>{
    for (final KeymapMode mode in KeymapMode.values)
      mode: Map<KeyChordSequence, String>.from(bindings),
  });
}

// --- Stateful dispatch --------------------------------------------------------

/// What an app must do to its editor buffer after an IME intent fired.
///
/// For convert / cycle / IME-backspace the app simply repaints the active region
/// from [ImeController.state] (both text fields null). [committed] is the
/// finalized string to insert (and the active region cleared); [cancelled] is
/// the raw hiragana the conversion reverted to.
@immutable
class AnthyDispatchResult {
  /// Create a result. [committed] and [cancelled] are mutually exclusive and set
  /// only by commit / cancel respectively.
  const AnthyDispatchResult({
    required this.handled,
    this.committed,
    this.cancelled,
  });

  /// The id was not an Anthy IME intent — the caller should handle it elsewhere.
  static const AnthyDispatchResult unhandled =
      AnthyDispatchResult(handled: false);

  /// Whether [dispatchAnthyIntent] recognised and ran the intent.
  final bool handled;

  /// The finalized text a commit produced — insert it and clear the active
  /// region. Null unless the intent was [kCommitConversionId].
  final String? committed;

  /// The raw hiragana a cancel reverted to. Null unless the intent was
  /// [kCancelConversionId].
  final String? cancelled;
}

/// Drive [controller] for the Anthy IME intent [id] and report what the editor
/// buffer should do. Unknown ids return [AnthyDispatchResult.unhandled] without
/// touching the controller. The single place the intent→controller mapping
/// lives, so no app re-implements the switch.
Future<AnthyDispatchResult> dispatchAnthyIntent(
  ImeController controller,
  String id,
) async {
  switch (id) {
    case kConvertOrNextCandidateId:
      await controller.space();
      return const AnthyDispatchResult(handled: true);
    case kPreviousCandidateId:
      await controller.shiftSpace();
      return const AnthyDispatchResult(handled: true);
    case kImeBackspaceId:
      controller.backspace();
      return const AnthyDispatchResult(handled: true);
    case kCommitConversionId:
      final String text = await controller.commit();
      return AnthyDispatchResult(handled: true, committed: text);
    case kCancelConversionId:
      final String text = controller.cancel();
      return AnthyDispatchResult(handled: true, cancelled: text);
    case kMoveSegmentNextId:
      await controller.moveSegmentNext();
      return const AnthyDispatchResult(handled: true);
    case kMoveSegmentPreviousId:
      await controller.moveSegmentPrevious();
      return const AnthyDispatchResult(handled: true);
    case kShrinkSegmentId:
      await controller.shrinkSegment();
      return const AnthyDispatchResult(handled: true);
    case kGrowSegmentId:
      await controller.growSegment();
      return const AnthyDispatchResult(handled: true);
    case kToggleScriptId:
      controller.toggleScript();
      return const AnthyDispatchResult(handled: true);
    default:
      return AnthyDispatchResult.unhandled;
  }
}

/// What a [dispatchPreeditIntent] call did.
///
/// [outcome] is set only by the terminal intents — commit ([PreeditOutcome
/// .committed]) and cancel ([PreeditOutcome.reverted], null on the first,
/// still-composing stage of the two-stage Esc). Every other intent leaves it
/// null: the session has already re-spliced the host, so the caller needs to do
/// nothing but repaint.
@immutable
class PreeditDispatchResult {
  /// Create a result.
  const PreeditDispatchResult({required this.handled, this.outcome});

  /// The id was not an Anthy IME intent — the caller should handle it elsewhere.
  static const PreeditDispatchResult unhandled =
      PreeditDispatchResult(handled: false);

  /// Whether [dispatchPreeditIntent] recognised and ran the intent.
  final bool handled;

  /// The terminal outcome, when the intent committed or abandoned the preedit.
  final PreeditOutcome? outcome;
}

/// Drive [session] for the Anthy IME intent [id] — the [PreeditSession] twin of
/// [dispatchAnthyIntent].
///
/// Prefer this in any host that owns a [PreeditSession]: it drives the SESSION,
/// so the single preedit region stays in sync and commit/cancel splice the host
/// text automatically. [dispatchAnthyIntent] drives the bare [ImeController] and
/// leaves all region tracking to the caller — which is exactly the per-consumer
/// re-invention [PreeditSession] exists to delete. Having both here keeps the
/// intent→action mapping in ONE place; a host must never re-implement the switch.
///
/// Unknown ids return [PreeditDispatchResult.unhandled] without touching the
/// session.
Future<PreeditDispatchResult> dispatchPreeditIntent(
  PreeditSession session,
  String id,
) async {
  switch (id) {
    case kConvertOrNextCandidateId:
      await session.space();
      return const PreeditDispatchResult(handled: true);
    case kPreviousCandidateId:
      await session.shiftSpace();
      return const PreeditDispatchResult(handled: true);
    case kImeBackspaceId:
      session.backspace();
      return const PreeditDispatchResult(handled: true);
    case kCommitConversionId:
      return PreeditDispatchResult(
        handled: true,
        outcome: await session.commit(),
      );
    case kCancelConversionId:
      return PreeditDispatchResult(
        handled: true,
        outcome: await session.cancel(),
      );
    case kMoveSegmentNextId:
      await session.moveSegmentNext();
      return const PreeditDispatchResult(handled: true);
    case kMoveSegmentPreviousId:
      await session.moveSegmentPrevious();
      return const PreeditDispatchResult(handled: true);
    case kShrinkSegmentId:
      await session.shrinkSegment();
      return const PreeditDispatchResult(handled: true);
    case kGrowSegmentId:
      await session.growSegment();
      return const PreeditDispatchResult(handled: true);
    case kToggleScriptId:
      session.toggleScript();
      return const PreeditDispatchResult(handled: true);
    default:
      return PreeditDispatchResult.unhandled;
  }
}
