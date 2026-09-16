/// M-: (eval-expression) — a small, side-effect-free elisp evaluator for
/// desktop_kit, built over the kit's own sexp reader (`desktop_kit_config.dart`).
///
/// Deliberately tiny: enough for what M-: is actually used for at the echo
/// area — arithmetic, string glue, and live-buffer introspection ((point),
/// (buffer-name), (line-number-at-pos), …) — not a general elisp. No
/// setq/defun/let, no buffer mutation: unsupported forms raise a clean error
/// naming the symbol.
///
/// Kept separate from `desktop_kit_config.dart`: that module seeds
/// configuration from a harvested `.emacs`, it does NOT execute the config —
/// bundling an executor here would contradict that stated boundary.
///
/// Includes:
/// - [evalElisp] — evaluate source against an [ElispEnv] snapshot, rendered
///   echo-area style
/// - [resolveConfigConditional] — resolve a harvested `when`/`unless` config
///   conditional against an [ElispEnv], for the seam with [ConfigHarvester]
/// - [ElispEnv] / [ElispEvalException] / [renderElisp]
///
/// Opt-in, like the anthy/kana bridges: NOT re-exported from `desktop_kit.dart`.
library;

export 'src/elisp_eval/elisp_eval.dart';
