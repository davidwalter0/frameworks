/// Emacs-config harvester for desktop_kit — Phase 0 of the Emacs-compatible
/// editor direction (see the ui-kit-private design doc
/// `docs/design/emacs-compat-editor-architecture-evaluation.org`).
///
/// Reads an Emacs init file and extracts its *declarative* subset as a
/// [ConfigSeed] — keybindings, faces, and settings — that the kit consumes
/// without an elisp evaluator. It *seeds* configuration; it does NOT execute the
/// config. Everything it cannot interpret is reported as a [HarvestedDiagnostic]
/// (no silent drops).
///
/// Includes:
/// - [ConfigHarvester] — `harvest(source)` → [ConfigSeed]
/// - [ConfigSeed] and its parts ([HarvestedBinding] / [HarvestedFace] /
///   [HarvestedSetting] / [HarvestedDiagnostic]); [ConfigSeed.keymapTokens]
///   yields the `sequence-token → command` shape [KeymapConfig] persists
/// - [parseEmacsKey] / [tryParseEmacsKey] — Emacs key notation ("C-x C-s") →
///   the kit's [KeyChordSequence]
/// - [readAll] and the [SExpr] tree — the standalone elisp reader
///
/// Harvested command names are Emacs symbols; binding them to kit intent ids is
/// the app-level integration step and is intentionally left to the consumer.
library;

export 'src/config/config_harvester.dart';
export 'src/config/config_seed.dart';
export 'src/config/emacs_kbd.dart';
export 'src/config/sexp.dart';
