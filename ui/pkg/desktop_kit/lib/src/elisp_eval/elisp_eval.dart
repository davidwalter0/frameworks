// M-: (eval-expression) — a SMALL elisp evaluator over the kit's sexp reader.
//
// Deliberately tiny and side-effect free: enough for what M-: is actually
// used for at the echo area — arithmetic, string glue, and live-buffer
// introspection ((point), (buffer-name), (line-number-at-pos), …) — not a
// general elisp. No setq/defun/let, no buffer MUTATION: unsupported forms
// raise a clean error naming the symbol, exactly the honest boundary. The
// reader is the kit's own ([readAll] — the same one the config harvester
// parses `.emacs` with), so quoting, strings, chars and vectors already
// behave like Emacs's reader.
library;

import '../config/config_seed.dart' show HarvestedSetting;
import '../config/sexp.dart';

/// The live-buffer facts the introspection forms answer from. Elisp positions
/// are 1-based ([point] = caret + 1); [column] is 0-based like
/// `current-column`.
class ElispEnv {
  /// Create an environment snapshot for one evaluation.
  const ElispEnv({
    this.point = 1,
    this.pointMax = 1,
    this.bufferSize = 0,
    this.bufferName = '*scratch*',
    this.line = 1,
    this.column = 0,
    this.systemType = 'gnu/linux',
    this.env = const <String, String>{},
  });

  /// 1-based caret position (`(point)`).
  final int point;

  /// 1-based end position (`(point-max)` = buffer size + 1).
  final int pointMax;

  /// Buffer length in characters (`(buffer-size)`).
  final int bufferSize;

  /// `(buffer-name)`.
  final String bufferName;

  /// 1-based caret line (`(line-number-at-pos)`).
  final int line;

  /// 0-based caret column (`(current-column)`).
  final int column;

  /// Config-time platform tag (`system-type`), e.g. `gnu/linux`, `darwin`,
  /// `windows-nt`. Evaluating the bare symbol `system-type` yields this
  /// string (rendered elisp-style, unquoted, like a symbol).
  final String systemType;

  /// Backing store for `(getenv "VAR")`. Unknown names evaluate to nil,
  /// exactly like a real, unset environment variable.
  final Map<String, String> env;
}

/// Raised for anything the small evaluator does not support or a form that
/// misbehaves — the message is what the echo area shows.
class ElispEvalException implements Exception {
  /// Create an evaluation error carrying the echo-area [message].
  const ElispEvalException(this.message);

  /// Echo-area text (mirrors Emacs's error shapes, e.g.
  /// `void-function: foo`).
  final String message;

  @override
  String toString() => message;
}

/// Evaluate [source] (one or more forms; the LAST form's value is returned,
/// progn-at-top-level like `M-:`) against [env] and render the result the way
/// the echo area would: `3`, `"ab"`, `t`, `nil`, `(1 2 3)`.
String evalElisp(String source, ElispEnv env) {
  final List<SExpr> forms;
  try {
    forms = readAll(source);
  } on SExprReadException catch (e) {
    throw ElispEvalException('read error: $e');
  }
  if (forms.isEmpty) {
    throw const ElispEvalException('read error: empty expression');
  }
  Object? value;
  for (final SExpr form in forms) {
    value = _eval(form, env);
  }
  return renderElisp(value);
}

/// Resolve a harvested **config conditional** — a top-level `(when COND
/// (setq VAR VAL …) …)` / `(unless COND (setq VAR VAL …) …)` form — against
/// [env], returning the [HarvestedSetting]s the guarded `setq`/`setq-default`
/// bodies would install when the guard holds.
///
/// This is the seam between the harvester and the evaluator: the config
/// harvester (`ConfigHarvester`) does not understand `when`/`unless` — a
/// conditional form is reported as a [HarvestedDiagnostic] ("unhandled form
/// when"), not silently dropped. This evaluator *does* understand the guard
/// (`eq`, `system-type`, `member`, `getenv`, …, added for exactly this), but
/// deliberately does NOT understand `setq` as an executable form (no
/// mutation, per the file header) — so rather than "evaluating" the whole
/// `when` form, this function evaluates ONLY [SExpr] guard subform and, when
/// it holds, structurally extracts the guarded `setq` pairs the same way
/// [ConfigHarvester] extracts an unconditional `setq`. The `setq` VALUE
/// subforms ARE evaluated (numbers/strings/quoted data are self-evaluating
/// in this tiny evaluator), so `(setq tab-width (+ 2 2))` resolves to `4`
/// just like a plain harvested setting would.
///
/// Returns the empty list when [source] doesn't parse, isn't a
/// `when`/`unless` form, the guard is false under [env], or the guard itself
/// raises (an unsupported guard is treated as "doesn't apply", not a crash —
/// consistent with the harvester's diagnostic-not-throw philosophy).
List<HarvestedSetting> resolveConfigConditional(String source, ElispEnv env) {
  final List<SExpr> forms;
  try {
    forms = readAll(source);
  } on SExprReadException {
    return const <HarvestedSetting>[];
  }
  if (forms.isEmpty) return const <HarvestedSetting>[];
  final SExpr top = forms.first;
  if (top is! SList || top.items.length < 2) {
    return const <HarvestedSetting>[];
  }
  final String? head = top.head;
  if (head != 'when' && head != 'unless') return const <HarvestedSetting>[];

  final bool guardHolds;
  try {
    final Object? cond = _eval(top.items[1], env);
    final bool truthy = cond != null && cond != false;
    guardHolds = head == 'when' ? truthy : !truthy;
  } on ElispEvalException {
    return const <HarvestedSetting>[];
  }
  if (!guardHolds) return const <HarvestedSetting>[];

  final out = <HarvestedSetting>[];
  for (final SExpr bodyForm in top.items.skip(2)) {
    if (bodyForm is! SList) continue;
    final String? bodyHead = bodyForm.head;
    if (bodyHead != 'setq' && bodyHead != 'setq-default') continue;
    final List<SExpr> args = bodyForm.items.skip(1).toList();
    for (int i = 0; i + 1 < args.length; i += 2) {
      final SExpr lhs = args[i];
      if (lhs is! SSymbol) continue;
      final Object? value;
      try {
        value = _eval(args[i + 1], env);
      } on ElispEvalException {
        continue;
      }
      out.add(HarvestedSetting(
        name: lhs.name,
        value: value,
        raw: renderElisp(value),
      ));
    }
  }
  return out;
}

/// Render a Dart value elisp-style: null -> `nil`, true -> `t`, whole doubles
/// as integers, strings quoted, lists parenthesized.
String renderElisp(Object? v) {
  if (v == null) return 'nil';
  if (v == true) return 't';
  if (v is num) {
    if (v is double && v == v.roundToDouble() && v.isFinite) {
      return v.toInt().toString();
    }
    return v.toString();
  }
  if (v is String) return '"$v"';
  if (v is List<Object?>) {
    return '(${v.map(renderElisp).join(' ')})';
  }
  return v.toString();
}

Object? _eval(SExpr e, ElispEnv env) {
  switch (e) {
    case SNumber():
      return e.value;
    case SString():
      return e.value;
    case SChar():
      // a char literal reads as its code point, like elisp
      return e.simpleCodeUnit ??
          (throw ElispEvalException('unsupported char literal: ?${e.text}'));
    case SQuote():
      return _datum(e.value);
    case SVector():
      return <Object?>[for (final SExpr x in e.items) _eval(x, env)];
    case SSymbol():
      return switch (e.name) {
        'nil' => null,
        't' => true,
        'system-type' => env.systemType,
        _ => throw ElispEvalException('void-variable: ${e.name}'),
      };
    case SList():
      return _apply(e, env);
  }
}

/// A quoted datum evaluates to itself, structurally.
Object? _datum(SExpr e) => switch (e) {
      SNumber() => e.value,
      SString() => e.value,
      SChar() => e.simpleCodeUnit ?? e.text,
      SSymbol() when e.name == 'nil' => null,
      SSymbol() when e.name == 't' => true,
      SSymbol() => e.name,
      SQuote() => <Object?>['quote', _datum(e.value)],
      SList() => <Object?>[for (final SExpr x in e.items) _datum(x)],
      SVector() => <Object?>[for (final SExpr x in e.items) _datum(x)],
    };

Object? _apply(SList list, ElispEnv env) {
  if (list.items.isEmpty) return null; // () is nil
  final SExpr head = list.items.first;
  if (head is! SSymbol) {
    throw ElispEvalException('invalid-function: ${renderElisp(_datum(head))}');
  }
  final String fn = head.name;
  final List<SExpr> argForms = list.items.sublist(1);

  // Special forms first (unevaluated arguments).
  switch (fn) {
    case 'quote':
      return argForms.isEmpty ? null : _datum(argForms.first);
    case 'if':
      if (argForms.length < 2) {
        throw const ElispEvalException('wrong-number-of-arguments: if');
      }
      final Object? cond = _eval(argForms[0], env);
      if (cond != null && cond != false) return _eval(argForms[1], env);
      Object? v;
      for (final SExpr elseForm in argForms.sublist(2)) {
        v = _eval(elseForm, env);
      }
      return v;
    case 'and':
      Object? v = true;
      for (final SExpr f in argForms) {
        v = _eval(f, env);
        if (v == null || v == false) return null;
      }
      return v;
    case 'or':
      for (final SExpr f in argForms) {
        final Object? v = _eval(f, env);
        if (v != null && v != false) return v;
      }
      return null;
    case 'progn':
      Object? v;
      for (final SExpr f in argForms) {
        v = _eval(f, env);
      }
      return v;
    case 'when':
      if (argForms.isEmpty) {
        throw const ElispEvalException('wrong-number-of-arguments: when');
      }
      final Object? cond = _eval(argForms[0], env);
      if (cond == null || cond == false) return null;
      Object? v;
      for (final SExpr f in argForms.sublist(1)) {
        v = _eval(f, env);
      }
      return v;
    case 'unless':
      if (argForms.isEmpty) {
        throw const ElispEvalException('wrong-number-of-arguments: unless');
      }
      final Object? cond = _eval(argForms[0], env);
      if (cond != null && cond != false) return null;
      Object? v;
      for (final SExpr f in argForms.sublist(1)) {
        v = _eval(f, env);
      }
      return v;
  }

  final List<Object?> args = <Object?>[
    for (final SExpr f in argForms) _eval(f, env),
  ];

  num asNum(Object? v) {
    if (v is num) return v;
    throw ElispEvalException(
        'wrong-type-argument: number-or-marker-p, ${renderElisp(v)}');
  }

  switch (fn) {
    // ── arithmetic ──
    case '+':
      return args.fold<num>(0, (num a, Object? b) => a + asNum(b));
    case '*':
      return args.fold<num>(1, (num a, Object? b) => a * asNum(b));
    case '-':
      if (args.isEmpty) return 0;
      if (args.length == 1) return -asNum(args[0]);
      return args
          .sublist(1)
          .fold<num>(asNum(args[0]), (num a, Object? b) => a - asNum(b));
    case '/':
      if (args.length < 2) {
        throw const ElispEvalException('wrong-number-of-arguments: /');
      }
      return args.sublist(1).fold<num>(asNum(args[0]), (num a, Object? b) {
        final num d = asNum(b);
        if (d == 0) throw const ElispEvalException('arith-error');
        final num r = a / d;
        // Integer division for integer operands, like elisp.
        return (a is int && d is int) ? (a ~/ d) : r;
      });
    case 'mod':
      if (args.length != 2) {
        throw const ElispEvalException('wrong-number-of-arguments: mod');
      }
      return asNum(args[0]) % asNum(args[1]);
    case '1+':
      return asNum(args.single) + 1;
    case '1-':
      return asNum(args.single) - 1;
    case 'abs':
      return asNum(args.single).abs();
    case 'max':
      return args.map(asNum).reduce((num a, num b) => a > b ? a : b);
    case 'min':
      return args.map(asNum).reduce((num a, num b) => a < b ? a : b);
    // ── comparison / predicates ──
    case '=':
      return asNum(args[0]) == asNum(args[1]) ? true : null;
    case '/=':
      return asNum(args[0]) != asNum(args[1]) ? true : null;
    case '<':
      return asNum(args[0]) < asNum(args[1]) ? true : null;
    case '>':
      return asNum(args[0]) > asNum(args[1]) ? true : null;
    case '<=':
      return asNum(args[0]) <= asNum(args[1]) ? true : null;
    case '>=':
      return asNum(args[0]) >= asNum(args[1]) ? true : null;
    case 'not':
    case 'null':
      return (args.single == null || args.single == false) ? true : null;
    case 'equal':
      return renderElisp(args[0]) == renderElisp(args[1]) ? true : null;
    case 'eq':
      if (args.length != 2) {
        throw const ElispEvalException('wrong-number-of-arguments: eq');
      }
      return _eqLike(args[0], args[1]) ? true : null;
    case 'member':
      if (args.length != 2) {
        throw const ElispEvalException('wrong-number-of-arguments: member');
      }
      final Object? needle = args[0];
      final Object? haystack = args[1];
      if (haystack == null) return null;
      if (haystack is! List<Object?>) {
        throw ElispEvalException(
            'wrong-type-argument: listp, ${renderElisp(haystack)}');
      }
      for (int i = 0; i < haystack.length; i++) {
        if (renderElisp(haystack[i]) == renderElisp(needle)) {
          return haystack.sublist(i);
        }
      }
      return null;
    // ── strings ──
    case 'string=':
      return (args[0] as String? ?? '') == (args[1] as String? ?? '')
          ? true
          : null;
    case 'string-prefix-p':
      return (args[1] as String? ?? '').startsWith(args[0] as String? ?? '')
          ? true
          : null;
    case 'string-suffix-p':
      return (args[1] as String? ?? '').endsWith(args[0] as String? ?? '')
          ? true
          : null;
    case 'getenv':
      final Object? name = args.single;
      if (name is! String) {
        throw const ElispEvalException('wrong-type-argument: stringp');
      }
      return env.env[name];
    case 'concat':
      return args.map((Object? a) => a is String ? a : renderElisp(a)).join();
    case 'length':
      final Object? v = args.single;
      if (v is String) return v.length;
      if (v is List) return v.length;
      if (v == null) return 0;
      throw ElispEvalException(
          'wrong-type-argument: sequencep, ${renderElisp(v)}');
    case 'upcase':
      return (args.single as String? ?? '').toUpperCase();
    case 'downcase':
      return (args.single as String? ?? '').toLowerCase();
    case 'format':
    case 'message':
      final Object? fmt = args.isEmpty ? null : args.first;
      if (fmt is! String) {
        throw const ElispEvalException('wrong-type-argument: stringp');
      }
      return _format(fmt, args.sublist(1));
    // ── buffer introspection ──
    case 'point':
      return env.point;
    case 'point-min':
      return 1;
    case 'point-max':
      return env.pointMax;
    case 'buffer-size':
      return env.bufferSize;
    case 'buffer-name':
      return env.bufferName;
    case 'line-number-at-pos':
      return env.line;
    case 'current-column':
      return env.column;
    // ── lists ──
    case 'list':
      return args;
    case 'car':
      final Object? v = args.single;
      if (v == null) return null;
      if (v is List<Object?>) return v.isEmpty ? null : v.first;
      throw ElispEvalException('wrong-type-argument: listp, ${renderElisp(v)}');
    case 'cdr':
      final Object? v = args.single;
      if (v == null) return null;
      if (v is List<Object?>) {
        return v.length <= 1 ? null : v.sublist(1);
      }
      throw ElispEvalException('wrong-type-argument: listp, ${renderElisp(v)}');
  }
  throw ElispEvalException('void-function: $fn');
}

/// `eq`-like identity: for the atoms this evaluator represents (numbers,
/// strings/symbols, nil, t), Dart's `==` already means "same value" — good
/// enough for the config-time `(eq system-type 'gnu/linux)` idiom this
/// evaluator exists to resolve. Lists are never `eq` unless literally the
/// same object, matching elisp's cons-cell identity semantics.
bool _eqLike(Object? a, Object? b) {
  if (a is List<Object?> || b is List<Object?>) return identical(a, b);
  return a == b;
}

/// The `format` subset that covers echo-area use: %s %d %S %% .
String _format(String fmt, List<Object?> args) {
  final StringBuffer out = StringBuffer();
  int argI = 0;
  for (int i = 0; i < fmt.length; i++) {
    final String c = fmt[i];
    if (c != '%' || i + 1 >= fmt.length) {
      out.write(c);
      continue;
    }
    i++;
    final String d = fmt[i];
    switch (d) {
      case '%':
        out.write('%');
      case 's':
        final Object? a = argI < args.length ? args[argI++] : null;
        out.write(a is String ? a : renderElisp(a));
      case 'S':
        out.write(renderElisp(argI < args.length ? args[argI++] : null));
      case 'd':
        final Object? a = argI < args.length ? args[argI++] : null;
        if (a is! num) {
          throw const ElispEvalException(
              'format: wrong-type-argument: numberp');
        }
        out.write(a.toInt());
      default:
        throw ElispEvalException('format: unsupported directive %$d');
    }
  }
  return out.toString();
}
