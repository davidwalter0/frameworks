/// Anthy kana→kanji IME driver for desktop_kit.
///
/// Includes:
/// - [AnthyProcess] — transport abstraction over a long-running
///   `anthy-agent --egg` subprocess (dependency-injectable so tests can
///   substitute a scripted fake and never spawn a real process). The
///   subprocess-backed `SystemAnthyProcess` lives in
///   `desktop_kit_anthy_io.dart`, so this entrypoint compiles for web and a
///   browser build can supply its own transport (or none).
/// - [AnthyEgg] — the line-oriented egg-protocol driver: [AnthyEgg.start],
///   [AnthyEgg.convert], [AnthyEgg.candidates], [AnthyEgg.selectCandidate],
///   [AnthyEgg.resizeSegment], [AnthyEgg.commit], [AnthyEgg.close], plus the
///   [AnthyEgg.isAvailable] PATH pre-flight check
/// - [AnthySegment] / [AnthyConversion] — the parsed per-segment / whole-
///   conversion result types ([AnthyEggException] on a malformed/error reply)
/// - [ImePhase] / [ImeState] / [ImeController] — the headless kana→kanji
///   conversion state machine that drives an injected [AnthyEgg]
/// - [PreeditSession] / [PreeditHost] / [PreeditSplice] / [PreeditRegion] —
///   the headless editing-session layer above [ImeController]: it tracks the
///   single preedit region and emits [PreeditSplice]s a host applies to its own
///   text model (an EmacsBuffer, a TextEditingController, …), so no consumer
///   re-invents region tracking or commit/cancel splicing
/// - [AnthyUserDictionary] / [AnthyUserWord] / [AnthyWordType] — anthy's
///   personal dictionary, for readings the SYSTEM dictionary has no kanji for
///   (おめでとう offers only kana out of the box). Pure parse/render; the file
///   I/O is `AnthyUserDictionaryFile` in `desktop_kit_anthy_io.dart`
///
/// Opt-in and Linux-oriented (`anthy-agent` is a Linux IME backend): apps
/// that only want the Emacs/CUA keymap engine or the pure kana/romaji engine
/// keep importing `desktop_kit_keymap.dart` / `desktop_kit_kana.dart` alone,
/// with no IME dependency pulled in. Apps layer their own state-management
/// glue (Riverpod, provider, …) and widgets on top of [ImeController] — this
/// module carries only the subprocess driver + headless controller, no
/// widgets and no state-management dependency.
library;

export 'src/anthy/anthy_egg.dart';
export 'src/anthy/anthy_process.dart';
export 'src/anthy/anthy_user_dictionary.dart';
export 'src/anthy/ime_controller.dart';
export 'src/anthy/preedit_session.dart';
