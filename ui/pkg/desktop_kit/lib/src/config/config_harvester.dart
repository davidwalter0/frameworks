// The declarative-config harvester: Emacs init text → [ConfigSeed].
//
// Walks the top-level forms read by [readAll] and extracts the *data-shaped*
// subset that the kit can consume without an elisp evaluator:
//
//   * keybindings — `global-set-key`, `keymap-global-set`, `define-key`,
//     `keymap-set` (key given as `(kbd "…")`, a plain kbd-syntax string, a
//     vector, or a bare char literal);
//   * faces       — `set-face-attribute`, `custom-set-faces`, `defface`;
//   * settings    — `setq`, `setq-default`, `custom-set-variables`;
//   * hooks       — `add-hook` (the *registration* only — see below);
//   * `use-package` — its `:bind` and `:custom` clauses.
//
// Everything else — `defun`, `require`, advice, other `use-package` keywords,
// and any key/face form the translator can't handle — becomes a
// [HarvestedDiagnostic]. This is by design: the harvester seeds *configuration*,
// never *behaviour*, and it reports precisely what it left behind. `add-hook` is
// the boundary case: the registration (hook name + handler name) is data and is
// harvested, but nothing is ever executed and a `lambda` handler's body is not
// modelled — it is recorded as the opaque handler `<lambda>`.
library;

import '../keymap/key_chord.dart';
import '../keymap/key_chord_sequence.dart';
import 'config_seed.dart';
import 'emacs_kbd.dart';
import 'sexp.dart';

/// Extracts a [ConfigSeed] from Emacs init source. Stateless; call [harvest].
class ConfigHarvester {
  /// Create a harvester.
  const ConfigHarvester();

  /// Harvest the declarative subset from [source]. The whole source must read
  /// cleanly first; a read error (unbalanced parens, unterminated string) is
  /// captured as a single diagnostic rather than thrown, yielding an otherwise
  /// empty seed. Per-form problems after a clean read become individual
  /// [HarvestedDiagnostic]s and never abort the harvest.
  ConfigSeed harvest(String source) {
    final bindings = <HarvestedBinding>[];
    final faces = <HarvestedFace>[];
    final settings = <HarvestedSetting>[];
    final hooks = <HarvestedHook>[];
    final diagnostics = <HarvestedDiagnostic>[];

    List<SExpr> forms;
    try {
      forms = readAll(source);
    } on SExprReadException catch (e) {
      diagnostics.add(HarvestedDiagnostic(
        form: '<source>',
        reason: 'read error: ${e.message} @ ${e.offset}',
      ));
      return ConfigSeed(
        bindings: bindings,
        faces: faces,
        settings: settings,
        hooks: hooks,
        diagnostics: diagnostics,
      );
    }

    for (final form in forms) {
      if (form is! SList || form.isEmpty) {
        diagnostics.add(_skip(form, 'top-level form is not a call'));
        continue;
      }
      try {
        _dispatch(form, bindings, faces, settings, hooks, diagnostics);
      } on _Skip catch (s) {
        diagnostics.add(_skip(form, s.reason));
      }
    }

    return ConfigSeed(
      bindings: bindings,
      faces: faces,
      settings: settings,
      hooks: hooks,
      diagnostics: diagnostics,
    );
  }

  void _dispatch(
    SList form,
    List<HarvestedBinding> bindings,
    List<HarvestedFace> faces,
    List<HarvestedSetting> settings,
    List<HarvestedHook> hooks,
    List<HarvestedDiagnostic> diagnostics,
  ) {
    switch (form.head) {
      case 'global-set-key':
        bindings.add(_binding(form, 'global', keyAt: 1, cmdAt: 2));
      case 'keymap-global-set':
        bindings.add(_binding(form, 'global', keyAt: 1, cmdAt: 2));
      case 'define-key':
        bindings.add(_binding(form, _keymapName(form, 1), keyAt: 2, cmdAt: 3));
      case 'keymap-set':
        bindings.add(_binding(form, _keymapName(form, 1), keyAt: 2, cmdAt: 3));
      case 'set-face-attribute':
        faces.add(_faceFromAttribute(form));
      case 'custom-set-faces':
        for (final spec in form.items.skip(1)) {
          faces.add(_faceFromCustomSpec(spec));
        }
      case 'setq':
      case 'setq-default':
        settings.addAll(_settingsFromSetq(form));
      case 'custom-set-variables':
        for (final spec in form.items.skip(1)) {
          settings.add(_settingFromCustomSpec(spec));
        }
      case 'defface':
        faces.add(_faceFromDefface(form));
      case 'add-hook':
        hooks.add(_hook(form));
      case 'use-package':
        _usePackage(form, bindings, settings, diagnostics);
      case null:
        throw const _Skip('call head is not a symbol');
      default:
        throw _Skip('unhandled form ${form.head}');
    }
  }

  // --- keybindings ---------------------------------------------------------

  HarvestedBinding _binding(
    SList form,
    String keymap, {
    required int keyAt,
    required int cmdAt,
  }) {
    if (form.items.length <= cmdAt) {
      throw const _Skip('binding form has too few arguments');
    }
    final (raw, seq) = _extractKey(form.items[keyAt]);
    final cmd = _extractCommand(form.items[cmdAt]);
    return HarvestedBinding(
      keymap: keymap,
      sequence: seq,
      command: cmd,
      rawKey: raw,
    );
  }

  String _keymapName(SList form, int at) {
    if (form.items.length <= at) throw const _Skip('missing keymap argument');
    final m = form.items[at];
    if (m is SSymbol) return m.name;
    if (m is SQuote && m.symbolName != null) return m.symbolName!;
    throw _Skip('non-symbol keymap ${_render(m)}');
  }

  (String, KeyChordSequence) _extractKey(SExpr key) {
    // (kbd "C-x C-s")
    if (key is SList && key.head == 'kbd') {
      if (key.items.length >= 2 && key.items[1] is SString) {
        final raw = (key.items[1] as SString).value;
        return (raw, _translate(raw));
      }
      throw const _Skip('(kbd …) argument is not a string');
    }
    // plain kbd-syntax string: either "C-c a" (space-separated strokes) or a
    // backslash key string like "\C-x\C-s" (successive escape tokens).
    if (key is SString) {
      final raw = key.value;
      if (raw.contains(r'\')) {
        return (raw, _translateBackslashString(raw));
      }
      return (raw, _translate(raw));
    }
    // Vector key form: [f9] (named-key symbol), [?\C-x ?\C-s] (char literals).
    if (key is SVector) {
      return _extractVectorKey(key);
    }
    // Bare char literal key, e.g. ?\C-s.
    if (key is SChar) {
      final raw = '?${key.text}';
      try {
        return (raw, KeyChordSequence.single(translateKeyToken(key.text, raw)));
      } on KbdParseException catch (e) {
        throw _Skip('untranslatable char key "$raw": ${e.message}');
      }
    }
    throw _Skip('unrecognised key form ${_render(key)}');
  }

  /// A vector key form: each item is a named-key [SSymbol] (`[f9]`, `[tab]`) or
  /// a character literal [SChar] (`[?\C-x ?\C-s]`); every item translates to one
  /// stroke of the resulting sequence.
  (String, KeyChordSequence) _extractVectorKey(SVector vec) {
    if (vec.items.isEmpty) throw const _Skip('empty vector key form');
    final raw = _render(vec);
    final chords = <KeyChord>[];
    for (final item in vec.items) {
      if (item is SSymbol) {
        final chord = namedKeyChord(item.name);
        if (chord == null) {
          throw _Skip('vector key: unknown named key ${_render(item)}');
        }
        chords.add(chord);
      } else if (item is SChar) {
        try {
          chords.add(translateKeyToken(item.text, raw));
        } on KbdParseException catch (e) {
          throw _Skip('untranslatable vector key "$raw": ${e.message}');
        }
      } else {
        throw _Skip('unsupported vector key item ${_render(item)}');
      }
    }
    return (raw, KeyChordSequence(chords));
  }

  KeyChordSequence _translateBackslashString(String raw) {
    try {
      return KeyChordSequence(translateBackslashKeyString(raw, raw));
    } on KbdParseException catch (e) {
      throw _Skip('untranslatable backslash key "$raw": ${e.message}');
    }
  }

  KeyChordSequence _translate(String raw) {
    try {
      return parseEmacsKey(raw);
    } on KbdParseException catch (e) {
      throw _Skip('untranslatable key "$raw": ${e.message}');
    }
  }

  String _extractCommand(SExpr cmd) {
    if (cmd is SQuote && cmd.symbolName != null) return cmd.symbolName!;
    if (cmd is SString)
      return cmd.value; // keymap-set uses string command names
    if (cmd is SSymbol) return cmd.name;
    throw _Skip('command is not a symbol/string: ${_render(cmd)}');
  }

  // --- faces ---------------------------------------------------------------

  HarvestedFace _faceFromAttribute(SList form) {
    // (set-face-attribute 'FACE FRAME :k v :k v …)
    if (form.items.length < 3)
      throw const _Skip('set-face-attribute too short');
    final name = _symbolName(form.items[1]) ??
        (throw _Skip('face is not a symbol: ${_render(form.items[1])}'));
    final attrs = _plist(form.items.skip(3).toList());
    return HarvestedFace(name: name, attributes: attrs);
  }

  HarvestedFace _faceFromCustomSpec(SExpr spec) {
    // '(FACE ((t (:k v …))))  — the display clause may or may not wrap attrs.
    final list = _unquoteList(spec) ??
        (throw _Skip('custom-set-faces spec is not a list: ${_render(spec)}'));
    if (list.items.isEmpty) throw const _Skip('empty face spec');
    final name = _symbolName(list.items.first) ??
        (throw _Skip(
            'face name is not a symbol: ${_render(list.items.first)}'));
    if (list.items.length < 2) throw _Skip('face $name has no display spec');
    return HarvestedFace(
      name: name,
      attributes: _attrsFromDisplaySpec(list.items[1], name),
    );
  }

  HarvestedFace _faceFromDefface(SList form) {
    // (defface NAME SPEC "doc" …) — SPEC carries the same display-clause shape
    // custom-set-faces uses, so the two share one reader. The doc string and any
    // trailing `:group`/`:version` keywords describe the *definition*, not the
    // appearance, and are intentionally not harvested.
    if (form.items.length < 3) throw const _Skip('defface too short');
    final name = _symbolName(form.items[1]) ??
        (throw _Skip(
            'defface name is not a symbol: ${_render(form.items[1])}'));
    return HarvestedFace(
      name: name,
      attributes: _attrsFromDisplaySpec(form.items[2], name),
    );
  }

  /// Read the attributes out of a face display spec — `((t (:k v …)) …)`, quoted
  /// or not — taking the FIRST display clause (`(DISPLAY ATTRS…)`, where DISPLAY
  /// is usually `t`). The attribute plist may or may not be wrapped in a list.
  /// Shared by `custom-set-faces` and `defface`.
  Map<String, String> _attrsFromDisplaySpec(SExpr spec, String faceName) {
    final specs = _unquoteList(spec) ??
        (throw _Skip('face $faceName display spec is not a list: '
            '${_render(spec)}'));
    if (specs.items.isEmpty || specs.items.first is! SList) {
      throw _Skip('face $faceName display spec malformed');
    }
    final clause = (specs.items.first as SList).items;
    final tail = clause.skip(1).toList();
    final plist = (tail.length == 1 && tail.first is SList)
        ? (tail.first as SList).items
        : tail;
    return _plist(plist);
  }

  Map<String, String> _plist(List<SExpr> items) {
    final out = <String, String>{};
    for (var i = 0; i + 1 < items.length; i += 2) {
      final k = items[i];
      if (k is! SSymbol || !k.isKeyword) break; // stop at first non-keyword
      out[k.name.substring(1)] = _renderAttr(items[i + 1]);
    }
    return out;
  }

  String _renderAttr(SExpr v) {
    if (v is SString) return v.value;
    if (v is SNumber) return _numText(v.value);
    if (v is SSymbol) return v.name;
    if (v is SQuote) return v.symbolName ?? _render(v.value);
    return _render(v);
  }

  // --- settings ------------------------------------------------------------

  List<HarvestedSetting> _settingsFromSetq(SList form) {
    final out = <HarvestedSetting>[];
    final args = form.items.skip(1).toList();
    for (var i = 0; i + 1 < args.length; i += 2) {
      final name = _symbolName(args[i]);
      if (name == null) continue; // skip a non-symbol lhs defensively
      final (value, raw) = _value(args[i + 1]);
      out.add(HarvestedSetting(name: name, value: value, raw: raw));
    }
    if (out.isEmpty) throw const _Skip('setq had no symbol/value pairs');
    return out;
  }

  HarvestedSetting _settingFromCustomSpec(SExpr spec) {
    // '(VAR VALUE …)
    final list = _unquoteList(spec) ??
        (throw _Skip('custom-set-variables spec not a list: ${_render(spec)}'));
    if (list.items.length < 2) throw const _Skip('custom var spec too short');
    final name = _symbolName(list.items.first) ??
        (throw const _Skip('custom var is not a symbol'));
    final (value, raw) = _value(list.items[1]);
    return HarvestedSetting(name: name, value: value, raw: raw);
  }

  (Object?, String) _value(SExpr v) {
    if (v is SString) return (v.value, jsonish(v.value));
    if (v is SNumber) return (v.value, _numText(v.value));
    if (v is SSymbol) {
      if (v.name == 't') return (true, 't');
      if (v.name == 'nil') return (false, 'nil');
      return (v.name, v.name); // a bare symbol value, kept as its name
    }
    if (v is SQuote && v.symbolName != null) {
      return (v.symbolName, "'${v.symbolName}");
    }
    return (null, _render(v)); // compound value: keep the source rendering only
  }

  // --- hooks ---------------------------------------------------------------

  HarvestedHook _hook(SList form) {
    // (add-hook 'HOOK #'fn) / (add-hook 'HOOK (lambda () …)) — the registration
    // is data; the handler is only ever NAMED, never run. A lambda's body is not
    // behaviour the harvester models, so it collapses to the opaque `<lambda>`.
    if (form.items.length < 3) {
      throw const _Skip('add-hook has too few arguments');
    }
    final hook = _symbolName(form.items[1]) ??
        (throw _Skip('hook is not a symbol: ${_render(form.items[1])}'));
    final h = form.items[2];
    final handler = _symbolName(h) ?? (_isLambda(h) ? '<lambda>' : null);
    if (handler == null) {
      throw _Skip('hook handler is not a symbol or lambda: ${_render(h)}');
    }
    return HarvestedHook(hook: hook, handler: handler);
  }

  bool _isLambda(SExpr e) {
    final l = _unquoteList(e);
    return l != null && (l.head == 'lambda' || l.head == 'closure');
  }

  // --- use-package ---------------------------------------------------------

  /// `(use-package NAME :bind (("C-c x" . cmd) …) :custom (var val) …)` — the
  /// declarative keywords (`:bind`, `:custom`) harvest as bindings/settings;
  /// every other keyword is a diagnostic naming it, since the rest of
  /// use-package (`:config`, `:init`, `:hook`, …) is code, not data.
  void _usePackage(
    SList form,
    List<HarvestedBinding> bindings,
    List<HarvestedSetting> settings,
    List<HarvestedDiagnostic> diagnostics,
  ) {
    if (form.items.length < 2) {
      throw const _Skip('use-package has no package name');
    }
    final pkg = _symbolName(form.items[1]) ??
        (throw _Skip(
            'use-package name is not a symbol: ${_render(form.items[1])}'));

    final rest = form.items.skip(2).toList();
    var i = 0;
    while (i < rest.length) {
      final kw = rest[i];
      if (kw is! SSymbol || !kw.isKeyword) {
        diagnostics
            .add(_skip(kw, 'use-package $pkg: expected a keyword clause'));
        i++;
        continue;
      }
      // Gather this keyword's arguments: everything up to the next keyword.
      i++;
      final args = <SExpr>[];
      while (i < rest.length && !_isKeyword(rest[i])) {
        args.add(rest[i]);
        i++;
      }
      switch (kw.name) {
        case ':bind':
          for (final a in args) {
            try {
              bindings.addAll(_bindClause(a));
            } on _Skip catch (s) {
              diagnostics.add(_skip(a, 'use-package $pkg :bind: ${s.reason}'));
            }
          }
        case ':custom':
          for (final a in args) {
            try {
              settings.add(_settingFromCustomSpec(a));
            } on _Skip catch (s) {
              diagnostics
                  .add(_skip(a, 'use-package $pkg :custom: ${s.reason}'));
            }
          }
        default:
          diagnostics.add(HarvestedDiagnostic(
            form: _render(SList(<SExpr>[kw, ...args])),
            reason: 'use-package $pkg: ${kw.name} not harvested',
          ));
      }
    }
  }

  /// One `:bind` argument: either a list of `(KEY . COMMAND)` pairs — the usual
  /// `(("C-c x" . cmd) ("C-c y" . cmd2))` — or a single bare pair.
  List<HarvestedBinding> _bindClause(SExpr spec) {
    final list = _unquoteList(spec) ??
        (throw _Skip('bind spec is not a list: ${_render(spec)}'));
    if (list.items.isEmpty) throw const _Skip('empty bind spec');
    final pairs = list.items.every((e) => _unquoteList(e) != null)
        ? list.items
        : <SExpr>[list];
    return <HarvestedBinding>[for (final p in pairs) _bindPair(p)];
  }

  HarvestedBinding _bindPair(SExpr spec) {
    final list = _unquoteList(spec) ??
        (throw _Skip('bind pair is not a list: ${_render(spec)}'));
    // The reader has no dotted-pair node: `.` arrives as a plain symbol atom
    // between the key and the command, so drop it to get the two operands.
    final items = list.items
        .where((e) => !(e is SSymbol && e.name == '.'))
        .toList(growable: false);
    if (items.length != 2) {
      throw _Skip('bind pair is not (KEY . COMMAND): ${_render(spec)}');
    }
    final (raw, seq) = _extractKey(items[0]);
    return HarvestedBinding(
      keymap: 'global',
      sequence: seq,
      command: _extractCommand(items[1]),
      rawKey: raw,
    );
  }

  bool _isKeyword(SExpr e) => e is SSymbol && e.isKeyword;

  // --- shared helpers ------------------------------------------------------

  String? _symbolName(SExpr e) {
    if (e is SSymbol) return e.name;
    if (e is SQuote && e.symbolName != null) return e.symbolName;
    return null;
  }

  SList? _unquoteList(SExpr e) {
    if (e is SList) return e;
    if (e is SQuote && e.value is SList) return e.value as SList;
    return null;
  }

  String _numText(num n) => n.toString();

  HarvestedDiagnostic _skip(SExpr form, String reason) =>
      HarvestedDiagnostic(form: _render(form), reason: reason);
}

/// Internal control-flow signal: a form (or sub-extraction) was intentionally
/// skipped, carrying the reason for its diagnostic.
class _Skip implements Exception {
  const _Skip(this.reason);
  final String reason;
}

/// A short, single-line rendering of a form for diagnostics (truncated).
String _render(SExpr e) {
  final s = _renderFull(e);
  return s.length <= 80 ? s : '${s.substring(0, 77)}…';
}

String _renderFull(SExpr e) => switch (e) {
      SSymbol(:final name) => name,
      SString(:final value) => jsonish(value),
      SNumber(:final value) => value.toString(),
      SChar(:final text) => '?$text',
      SVector(:final items) => '[${items.map(_renderFull).join(' ')}]',
      SList(:final items) => '(${items.map(_renderFull).join(' ')})',
      SQuote(:final kind, :final value) =>
        '${_quotePrefix(kind)}${_renderFull(value)}',
    };

String _quotePrefix(QuoteKind k) => switch (k) {
      QuoteKind.quote => "'",
      QuoteKind.function => "#'",
      QuoteKind.backquote => '`',
      QuoteKind.unquote => ',',
      QuoteKind.unquoteSplicing => ',@',
    };
