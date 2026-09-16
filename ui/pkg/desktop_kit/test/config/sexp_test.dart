// Tests for the elisp reader: atoms, lists, vectors, quotes, chars, comments.
import 'package:desktop_kit/desktop_kit_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('atoms', () {
    test('symbol', () {
      final forms = readAll('global-set-key');
      expect(forms, hasLength(1));
      expect(forms.single, isA<SSymbol>());
      expect((forms.single as SSymbol).name, 'global-set-key');
    });

    test('keyword symbol', () {
      expect((readAll(':foreground').single as SSymbol).isKeyword, isTrue);
      expect((readAll('foreground').single as SSymbol).isKeyword, isFalse);
    });

    test('integer and float', () {
      expect((readAll('4').single as SNumber).value, 4);
      expect((readAll('0.5').single as SNumber).value, 0.5);
      expect((readAll('-3').single as SNumber).value, -3);
    });

    test('a lone "-" is a symbol, not a number', () {
      expect(readAll('-').single, isA<SSymbol>());
    });

    test('string with escapes', () {
      expect((readAll(r'"a\tb\n"').single as SString).value, 'a\tb\n');
    });

    test('character literal', () {
      expect((readAll('?a').single as SChar).simpleCodeUnit, 0x61);
      expect((readAll(r'?\s').single as SChar).simpleCodeUnit, 0x20);
    });
  });

  group('compound forms', () {
    test('nested list and head', () {
      final l = readAll('(a (b c) d)').single as SList;
      expect(l.head, 'a');
      expect(l.items, hasLength(3));
      expect((l.items[1] as SList).head, 'b');
    });

    test('vector', () {
      final v = readAll('[a b c]').single as SVector;
      expect(v.items, hasLength(3));
    });

    test('quote and function-quote both expose the symbol', () {
      expect(
          (readAll("'save-buffer").single as SQuote).symbolName, 'save-buffer');
      final fq = readAll("#'org-agenda").single as SQuote;
      expect(fq.kind, QuoteKind.function);
      expect(fq.symbolName, 'org-agenda');
    });
  });

  group('trivia', () {
    test('line comments and blank lines are skipped', () {
      final forms = readAll('''
; a comment
(setq a 1)  ; trailing
; another
(setq b 2)
''');
      expect(forms, hasLength(2));
      expect((forms[0] as SList).head, 'setq');
      expect((forms[1] as SList).head, 'setq');
    });
  });

  group('errors', () {
    test('unbalanced list throws', () {
      expect(() => readAll('(a b'), throwsA(isA<SExprReadException>()));
    });

    test('stray close throws', () {
      expect(() => readAll('a)'), throwsA(isA<SExprReadException>()));
    });

    test('unterminated string throws', () {
      expect(() => readAll('"abc'), throwsA(isA<SExprReadException>()));
    });
  });
}
