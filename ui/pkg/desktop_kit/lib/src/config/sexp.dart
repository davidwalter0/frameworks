// A small, dependency-free Emacs-Lisp *reader* (s-expression parser).
//
// This is the front half of the declarative-config harvester: it turns elisp
// source text into a tree of [SExpr] nodes. It is a *reader*, not an evaluator —
// it understands elisp's surface syntax (lists, vectors, strings, symbols,
// numbers, character literals, quote/function-quote/backquote reader macros, and
// `;` line comments) but assigns no meaning to any form. The harvester
// ([ConfigHarvester]) walks the resulting tree and extracts the declarative
// subset (keybindings, faces, settings); everything else is left untouched for a
// diagnostic rather than mis-evaluated.
//
// Scope: the surface syntax that appears in real init files. Deliberately out of
// scope (a reader for *config*, not a full elisp reader): `#x`/`#o`/`#b` radix
// literals, `#(...)` string properties, `?\M-…` meta character literals, and
// circular `#N=`/`#N#` references. Unknown `#` dispatch is read as an opaque
// symbol so a form containing it can still be skipped cleanly.
library;

/// A parsed s-expression node. Sealed so a walker can switch exhaustively.
sealed class SExpr {
  const SExpr();
}

/// A symbol atom, e.g. `global-set-key`, `:foreground`, `t`, `nil`. Keyword
/// symbols (leading `:`) and the booleans `t`/`nil` are ordinary symbols here;
/// meaning is assigned by the harvester, not the reader.
final class SSymbol extends SExpr {
  /// Create a symbol named [name].
  const SSymbol(this.name);

  /// The symbol's print name, verbatim (case-sensitive).
  final String name;

  /// Whether this is a keyword symbol (`:foo`).
  bool get isKeyword => name.startsWith(':');

  @override
  bool operator ==(Object other) => other is SSymbol && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SSymbol($name)';
}

/// A string literal with its escapes already resolved to the runtime value.
final class SString extends SExpr {
  /// Create a string atom holding the decoded [value].
  const SString(this.value);

  /// The decoded string contents (escapes resolved).
  final String value;

  @override
  bool operator ==(Object other) => other is SString && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SString(${jsonish(value)})';
}

/// A numeric literal (integer or float).
final class SNumber extends SExpr {
  /// Create a number atom holding [value].
  const SNumber(this.value);

  /// The numeric value.
  final num value;

  @override
  bool operator ==(Object other) => other is SNumber && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SNumber($value)';
}

/// A character literal such as `?a` or `?\C-x`. [text] is the source form after
/// the leading `?` (e.g. `a`, `\C-x`, `\n`); [simpleCodeUnit] is the code unit
/// for the plain, unmodified cases and `null` when the literal carries modifier
/// escapes the reader does not resolve (those are left for a diagnostic).
final class SChar extends SExpr {
  /// Create a character literal from its post-`?` [text] and, when unmodified,
  /// its [simpleCodeUnit].
  const SChar(this.text, this.simpleCodeUnit);

  /// The source text following `?` (without the `?`).
  final String text;

  /// The code unit for a plain literal (`?a` → 97, `?\n` → 10), or `null` for a
  /// modifier literal (`?\C-x`) the reader leaves unresolved.
  final int? simpleCodeUnit;

  @override
  String toString() => 'SChar(?$text)';
}

/// A parenthesised list `( … )`.
final class SList extends SExpr {
  /// Create a list of [items].
  const SList(this.items);

  /// The element forms, in order.
  final List<SExpr> items;

  /// Whether the list is empty (`()`), which elisp also spells `nil`.
  bool get isEmpty => items.isEmpty;

  /// The head symbol name if this list's first element is a symbol, else `null`
  /// — the common "what kind of form is this?" query.
  String? get head => items.isNotEmpty && items.first is SSymbol
      ? (items.first as SSymbol).name
      : null;

  @override
  String toString() => 'SList(${items.join(' ')})';
}

/// A vector `[ … ]` (used by some keybinding forms, e.g. `[?\C-x]`).
final class SVector extends SExpr {
  /// Create a vector of [items].
  const SVector(this.items);

  /// The element forms, in order.
  final List<SExpr> items;

  @override
  String toString() => 'SVector(${items.join(' ')})';
}

/// The reader-macro flavours that wrap a following form.
enum QuoteKind {
  /// `'form` — quote.
  quote,

  /// `#'form` — function quote.
  function,

  /// `` `form `` — backquote / quasiquote.
  backquote,

  /// `,form` — unquote.
  unquote,

  /// `,@form` — unquote-splicing.
  unquoteSplicing,
}

/// A quoted form: one of the [QuoteKind] reader macros applied to [value].
/// For extraction purposes `'sym` and `#'sym` both denote the symbol `sym`;
/// [symbolName] gives it directly when [value] is a symbol.
final class SQuote extends SExpr {
  /// Create a quote node of [kind] wrapping [value].
  const SQuote(this.kind, this.value);

  /// Which reader macro produced this node.
  final QuoteKind kind;

  /// The wrapped form.
  final SExpr value;

  /// The wrapped symbol's name when [value] is a symbol (the common
  /// `'command` / `#'command` case), else `null`.
  String? get symbolName => value is SSymbol ? (value as SSymbol).name : null;

  @override
  String toString() => 'SQuote($kind $value)';
}

/// Thrown when the source cannot be read (unbalanced delimiters, unterminated
/// string, stray closing bracket). Carries the source [offset] of the fault.
class SExprReadException implements Exception {
  /// Create a read exception with a [message] and source [offset].
  const SExprReadException(this.message, this.offset);

  /// What went wrong.
  final String message;

  /// 0-based character offset into the source where reading failed.
  final int offset;

  @override
  String toString() => 'SExprReadException($message @ $offset)';
}

/// Read every top-level form in [source]. Comments and inter-form whitespace are
/// discarded. Throws [SExprReadException] on malformed input.
List<SExpr> readAll(String source) => _Reader(source).readAll();

// ---------------------------------------------------------------------------
// Reader implementation (tokeniser + recursive descent, one pass).
// ---------------------------------------------------------------------------

class _Reader {
  _Reader(this._src);

  final String _src;
  int _pos = 0;

  List<SExpr> readAll() {
    final out = <SExpr>[];
    while (true) {
      _skipTrivia();
      if (_atEnd) break;
      out.add(_readForm());
    }
    return out;
  }

  bool get _atEnd => _pos >= _src.length;
  int get _cur => _src.codeUnitAt(_pos);

  void _skipTrivia() {
    while (!_atEnd) {
      final c = _cur;
      if (c == 0x3B) {
        // ';' — comment to end of line.
        while (!_atEnd && _cur != 0x0A) {
          _pos++;
        }
      } else if (_isSpace(c)) {
        _pos++;
      } else {
        break;
      }
    }
  }

  SExpr _readForm() {
    _skipTrivia();
    if (_atEnd) {
      throw SExprReadException('unexpected end of input', _pos);
    }
    final c = _cur;
    switch (c) {
      case 0x28: // (
        return _readList(0x29, (items) => SList(items));
      case 0x5B: // [
        return _readList(0x5D, (items) => SVector(items));
      case 0x29: // )
      case 0x5D: // ]
        throw SExprReadException('unexpected close delimiter', _pos);
      case 0x27: // '
        _pos++;
        return SQuote(QuoteKind.quote, _readForm());
      case 0x60: // `
        _pos++;
        return SQuote(QuoteKind.backquote, _readForm());
      case 0x2C: // ,
        _pos++;
        if (!_atEnd && _cur == 0x40) {
          // ,@
          _pos++;
          return SQuote(QuoteKind.unquoteSplicing, _readForm());
        }
        return SQuote(QuoteKind.unquote, _readForm());
      case 0x23: // #
        return _readHash();
      case 0x22: // "
        return _readString();
      case 0x3F: // ?
        return _readChar();
      default:
        return _readAtom();
    }
  }

  SExpr _readList(int close, SExpr Function(List<SExpr>) build) {
    final open = _pos;
    _pos++; // consume opener
    final items = <SExpr>[];
    while (true) {
      _skipTrivia();
      if (_atEnd) {
        throw SExprReadException('unterminated list', open);
      }
      if (_cur == close) {
        _pos++;
        return build(items);
      }
      // A dotted pair `. x` is rare in config; read the dot as a symbol atom so
      // the form still parses (the harvester ignores such lists).
      items.add(_readForm());
    }
  }

  SExpr _readHash() {
    // Only `#'` (function quote) is meaningful for config extraction. Any other
    // `#…` dispatch is read as an opaque symbol token so its enclosing form can
    // be skipped without a hard failure.
    if (_pos + 1 < _src.length && _src.codeUnitAt(_pos + 1) == 0x27) {
      _pos += 2; // #'
      return SQuote(QuoteKind.function, _readForm());
    }
    return _readAtom();
  }

  SString _readString() {
    final start = _pos;
    _pos++; // opening quote
    final b = StringBuffer();
    while (true) {
      if (_atEnd) {
        throw SExprReadException('unterminated string', start);
      }
      final c = _cur;
      _pos++;
      if (c == 0x22) {
        return SString(b.toString());
      }
      if (c == 0x5C) {
        // backslash escape
        if (_atEnd) {
          throw SExprReadException('unterminated string escape', start);
        }
        final e = _cur;
        _pos++;
        b.write(_stringEscape(e));
      } else {
        b.writeCharCode(c);
      }
    }
  }

  String _stringEscape(int e) {
    switch (e) {
      case 0x6E: // n
        return '\n';
      case 0x74: // t
        return '\t';
      case 0x72: // r
        return '\r';
      case 0x65: // e
        return '\x1b';
      case 0x22: // "
        return '"';
      case 0x5C: // backslash
        return r'\';
      default:
        // Unknown escape (incl. `\C-`, `\M-` used in key strings): keep the
        // backslash + char verbatim so a later stage can recognise or diagnose
        // it rather than silently corrupting the token.
        return '\\${String.fromCharCode(e)}';
    }
  }

  SChar _readChar() {
    _pos++; // consume '?'
    if (_atEnd) {
      throw SExprReadException('unterminated character literal', _pos);
    }
    final c = _cur;
    if (c == 0x5C) {
      // escape sequence: ?\n, ?\t, ?\C-x, ?\s, …
      _pos++; // backslash
      if (_atEnd) {
        throw SExprReadException('unterminated character escape', _pos);
      }
      final e = _cur;
      _pos++;
      // Simple named escapes resolve to a code unit; modifier escapes (C-, M-,
      // S-, s-) and anything else are left unresolved (simpleCodeUnit == null).
      final simple = _simpleCharEscape(e);
      if (simple != null) {
        return SChar('\\${String.fromCharCode(e)}', simple);
      }
      // Modifier or multi-char escape: capture the rest of the token verbatim.
      final tb = StringBuffer('\\${String.fromCharCode(e)}');
      while (!_atEnd && !_isDelimiter(_cur)) {
        tb.writeCharCode(_cur);
        _pos++;
      }
      return SChar(tb.toString(), null);
    }
    _pos++;
    return SChar(String.fromCharCode(c), c);
  }

  int? _simpleCharEscape(int e) {
    switch (e) {
      case 0x6E: // n
        return 0x0A;
      case 0x74: // t
        return 0x09;
      case 0x72: // r
        return 0x0D;
      case 0x65: // e
        return 0x1B;
      case 0x73: // s  (?\s == space)
        return 0x20;
      case 0x64: // d  (?\d == delete)
        return 0x7F;
      case 0x5C: // backslash
        return 0x5C;
      default:
        return null;
    }
  }

  SExpr _readAtom() {
    final start = _pos;
    while (!_atEnd && !_isDelimiter(_cur)) {
      // A backslash escapes the next char inside a symbol (rare); consume both.
      if (_cur == 0x5C && _pos + 1 < _src.length) {
        _pos += 2;
        continue;
      }
      _pos++;
    }
    final tok = _src.substring(start, _pos);
    if (tok.isEmpty) {
      throw SExprReadException('empty token', start);
    }
    final n = _parseNumber(tok);
    if (n != null) return SNumber(n);
    return SSymbol(tok);
  }

  static num? _parseNumber(String tok) {
    // Reject tokens that are clearly symbols even though they start numeric
    // (e.g. `1+`, `-`, `.`). A number is an optional sign, digits, optional
    // fractional/exponent — validated by int/double parse after a cheap guard.
    if (tok == '-' || tok == '+' || tok == '.') return null;
    final first = tok.codeUnitAt(0);
    final numeric = (first >= 0x30 && first <= 0x39) ||
        first == 0x2D ||
        first == 0x2B ||
        first == 0x2E;
    if (!numeric) return null;
    final i = int.tryParse(tok);
    if (i != null) return i;
    return double.tryParse(tok);
  }

  static bool _isSpace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C;

  bool _isDelimiter(int c) =>
      _isSpace(c) ||
      c == 0x28 || // (
      c == 0x29 || // )
      c == 0x5B || // [
      c == 0x5D || // ]
      c == 0x22 || // "
      c == 0x3B; // ;
}

/// Minimal double-quote-escaping helper for [SString.toString]/diagnostics —
/// not a full JSON encoder, just enough to make debug output readable.
String jsonish(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
