// The output of the declarative-config harvester: a "seed" the kit can consume.
//
// A [ConfigSeed] is the data-shaped slice extracted from an Emacs init file —
// keybindings, faces, settings, and hook registrations — plus
// [HarvestedDiagnostic]s for every form
// the harvester deliberately did NOT interpret (no silent drops). The bindings
// carry the kit's own [KeyChordSequence], so [keymapTokens] yields exactly the
// `sequence-token → value` shape [KeymapConfig] persists; wiring a harvested
// Emacs command name to a kit intent id is the app-level integration step and is
// intentionally left to the consumer.
library;

import '../keymap/key_chord_sequence.dart';

/// One harvested keybinding: an Emacs command bound to a key sequence in a
/// named keymap.
class HarvestedBinding {
  /// Create a binding of [command] to [sequence] in [keymap], remembering the
  /// original [rawKey] text for provenance.
  const HarvestedBinding({
    required this.keymap,
    required this.sequence,
    required this.command,
    required this.rawKey,
  });

  /// The keymap the binding lives in: `"global"` for `global-set-key`, else the
  /// elisp keymap variable name (e.g. `"org-mode-map"`).
  final String keymap;

  /// The translated key sequence (the kit's serialisable form).
  final KeyChordSequence sequence;

  /// The bound Emacs command (symbol) name, e.g. `save-buffer`.
  final String command;

  /// The original Emacs key text (e.g. `"C-x C-s"`) before translation.
  final String rawKey;

  /// JSON form: keymap, sequence token, sequence label, command, raw key.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'keymap': keymap,
        'token': sequence.token,
        'label': sequence.label,
        'command': command,
        'rawKey': rawKey,
      };

  @override
  String toString() =>
      'HarvestedBinding($keymap: ${sequence.label} → $command)';
}

/// One harvested face: a named face and its visual attributes (foreground,
/// background, weight, slant, underline, …) as string values.
class HarvestedFace {
  /// Create a face named [name] with [attributes].
  const HarvestedFace({required this.name, required this.attributes});

  /// The face name, e.g. `font-lock-keyword-face` or `org-level-1`.
  final String name;

  /// Attribute name (without the leading `:`) → value string, e.g.
  /// `{'foreground': '#81A1C1', 'weight': 'bold'}`.
  final Map<String, String> attributes;

  /// JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'attributes': attributes,
      };

  @override
  String toString() => 'HarvestedFace($name: $attributes)';
}

/// One harvested setting: a variable and its value (from `setq` /
/// `custom-set-variables`).
class HarvestedSetting {
  /// Create a setting of [name] to [value], keeping the source [raw] rendering.
  const HarvestedSetting({
    required this.name,
    required this.value,
    required this.raw,
  });

  /// The variable name, e.g. `tab-width`.
  final String name;

  /// The decoded value: [String], [num], [bool], or `null` (`nil`). A quoted or
  /// bare symbol is kept as its name [String]; a compound value is `null` with
  /// the source preserved in [raw].
  final Object? value;

  /// The source rendering of the value (provenance / compound fallback).
  final String raw;

  /// JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'value': value,
        'raw': raw,
      };

  @override
  String toString() => 'HarvestedSetting($name = $raw)';
}

/// One harvested hook registration: a handler attached to an Emacs hook
/// variable (from `add-hook`). The handler is *named*, never executed — the
/// harvester seeds configuration, not behaviour, so what a `lambda` body would
/// have done is deliberately not modelled. Wiring [handler] to kit behaviour is
/// the consumer's job.
class HarvestedHook {
  /// Create a registration of [handler] on [hook].
  const HarvestedHook({required this.hook, required this.handler});

  /// The hook variable name, e.g. `org-mode-hook`.
  final String hook;

  /// The handler's function name (e.g. `visual-line-mode`), or `'<lambda>'`
  /// when the handler is an inline lambda whose body is not harvested.
  final String handler;

  /// Whether [handler] is an inline lambda rather than a named function.
  bool get isLambda => handler == '<lambda>';

  /// JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'hook': hook,
        'handler': handler,
      };

  @override
  String toString() => 'HarvestedHook($hook → $handler)';
}

/// A form the harvester chose not to interpret, with the reason. Surfacing these
/// keeps the harvest honest: what did NOT come across is as important as what
/// did.
class HarvestedDiagnostic {
  /// Create a diagnostic for [form] with [reason].
  const HarvestedDiagnostic({required this.form, required this.reason});

  /// A short rendering of the skipped form.
  final String form;

  /// Why it was skipped (unsupported form, untranslatable key, …).
  final String reason;

  /// JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'form': form,
        'reason': reason,
      };

  @override
  String toString() => 'HarvestedDiagnostic($reason: $form)';
}

/// The full result of harvesting one config: the declarative subset plus the
/// diagnostics for everything skipped.
class ConfigSeed {
  /// Create a seed from its parts. [hooks] is optional so existing callers keep
  /// compiling; it defaults to no hook registrations.
  const ConfigSeed({
    required this.bindings,
    required this.faces,
    required this.settings,
    required this.diagnostics,
    this.hooks = const <HarvestedHook>[],
  });

  /// The harvested keybindings, in source order.
  final List<HarvestedBinding> bindings;

  /// The harvested faces, in source order.
  final List<HarvestedFace> faces;

  /// The harvested settings, in source order.
  final List<HarvestedSetting> settings;

  /// The harvested hook registrations, in source order. Reported as data; never
  /// executed.
  final List<HarvestedHook> hooks;

  /// The forms the harvester skipped, with reasons.
  final List<HarvestedDiagnostic> diagnostics;

  /// The `sequence-token → command` map for [keymap] (default `"global"`) — the
  /// shape [KeymapConfig] persists. A later binding to the same sequence wins
  /// (last-write, mirroring how a config's later `global-set-key` overrides an
  /// earlier one). The values are Emacs command names; mapping them to kit
  /// intent ids is the consumer's job.
  Map<String, String> keymapTokens({String keymap = 'global'}) {
    final out = <String, String>{};
    for (final b in bindings) {
      if (b.keymap == keymap) out[b.sequence.token] = b.command;
    }
    return out;
  }

  /// Every distinct keymap name that appears in [bindings].
  Set<String> get keymapNames => <String>{for (final b in bindings) b.keymap};

  /// The handler names registered on [hook], in source order.
  List<String> handlersFor(String hook) => <String>[
        for (final h in hooks)
          if (h.hook == hook) h.handler
      ];

  /// JSON form of the whole seed.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'bindings': <dynamic>[for (final b in bindings) b.toJson()],
        'faces': <dynamic>[for (final f in faces) f.toJson()],
        'settings': <dynamic>[for (final s in settings) s.toJson()],
        'hooks': <dynamic>[for (final h in hooks) h.toJson()],
        'diagnostics': <dynamic>[for (final d in diagnostics) d.toJson()],
      };

  @override
  String toString() =>
      'ConfigSeed(${bindings.length} bindings, ${faces.length} faces, '
      '${settings.length} settings, ${hooks.length} hooks, '
      '${diagnostics.length} diagnostics)';
}
