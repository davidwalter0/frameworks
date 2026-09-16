// Thorough headless tests for the pure Search model. Offsets below are
// hand-counted from the literal test strings and expectations are derived
// from the Emacs behavioural spec (case-fold-search + search-upper-case,
// wrapping isearch, non-overlapping replace-string), not read back off the
// implementation.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 'foo bar foo'
  //  01234567890  -> hits at [0,3) and [8,11)
  const String fooBarFoo = 'foo bar foo';

  group('matches', () {
    test('finds every occurrence, left to right', () {
      // 'hello world hello' -> hello@0, world@6, hello@12
      expect(
        Search.matches('hello world hello', 'hello'),
        const <SearchHit>[SearchHit(0, 5), SearchHit(12, 17)],
      );
    });

    test('an all-lower-case needle folds case (Emacs default)', () {
      // 'Hello hello HELLO' -> 0, 6, 12
      expect(
        Search.matches('Hello hello HELLO', 'hello'),
        const <SearchHit>[SearchHit(0, 5), SearchHit(6, 11), SearchHit(12, 17)],
      );
    });

    test('any upper-case in the needle forces a case-sensitive search', () {
      expect(
        Search.matches('Hello hello HELLO', 'Hello'),
        const <SearchHit>[SearchHit(0, 5)],
      );
      expect(
        Search.matches('Hello hello HELLO', 'HELLO'),
        const <SearchHit>[SearchHit(12, 17)],
      );
    });

    test('a needle of only non-letters still matches (folding is a no-op)', () {
      expect(
        Search.matches('a-b-c', '-'),
        const <SearchHit>[SearchHit(1, 2), SearchHit(3, 4)],
      );
    });

    test('folds non-ASCII letters', () {
      expect(Search.matches('Ünïcode', 'ünïcode'),
          const <SearchHit>[SearchHit(0, 7)]);
    });

    test('matches are non-overlapping — scan resumes at the hit end', () {
      expect(Search.matches('aaa', 'aa'), const <SearchHit>[SearchHit(0, 2)]);
      expect(
        Search.matches('aaaa', 'aa'),
        const <SearchHit>[SearchHit(0, 2), SearchHit(2, 4)],
      );
    });

    test('empty needle -> empty list', () {
      expect(Search.matches('anything', ''), isEmpty);
    });

    test('no match / needle longer than text / empty text -> empty list', () {
      expect(Search.matches('abc', 'zz'), isEmpty);
      expect(Search.matches('ab', 'abc'), isEmpty);
      expect(Search.matches('', 'a'), isEmpty);
    });

    test('a whole-text match is reported once', () {
      expect(Search.matches('abc', 'abc'), const <SearchHit>[SearchHit(0, 3)]);
    });
  });

  group('forward', () {
    test('finds the match starting exactly at from', () {
      expect(Search.forward(fooBarFoo, 0, 'foo'), const SearchHit(0, 3));
      expect(Search.forward(fooBarFoo, 8, 'foo'), const SearchHit(8, 11));
    });

    test('skips a hit the caret has already passed the start of', () {
      expect(Search.forward(fooBarFoo, 1, 'foo'), const SearchHit(8, 11));
    });

    test('wraps to 0 when no match remains at/after from', () {
      expect(Search.forward(fooBarFoo, 9, 'foo'), const SearchHit(0, 3));
      expect(Search.forward(fooBarFoo, 11, 'foo'), const SearchHit(0, 3));
    });

    test('clamps an out-of-range from (and still wraps)', () {
      expect(Search.forward(fooBarFoo, 999, 'foo'), const SearchHit(0, 3));
      expect(Search.forward(fooBarFoo, -5, 'foo'), const SearchHit(0, 3));
    });

    test('can report an overlapping hit the enumeration skips', () {
      // matches('aaaa','aa') enumerates [0,2) and [2,4); searching from 1
      // finds the overlapping hit at [1,3).
      expect(Search.forward('aaaa', 1, 'aa'), const SearchHit(1, 3));
    });

    test('folds case for a lower-case needle', () {
      expect(Search.forward('xxHELLO', 0, 'hello'), const SearchHit(2, 7));
      expect(Search.forward('xxHELLO', 0, 'Hello'), isNull);
    });

    test('null on no match and on an empty needle', () {
      expect(Search.forward(fooBarFoo, 0, 'zz'), isNull);
      expect(Search.forward(fooBarFoo, 0, ''), isNull);
    });
  });

  group('backward', () {
    test('finds the nearest match starting strictly before from', () {
      expect(Search.backward(fooBarFoo, 11, 'foo'), const SearchHit(8, 11));
      expect(Search.backward(fooBarFoo, 9, 'foo'), const SearchHit(8, 11));
    });

    test('a hit starting exactly at from is excluded (guarantees progress)',
        () {
      expect(Search.backward(fooBarFoo, 8, 'foo'), const SearchHit(0, 3));
    });

    test('wraps to the end when nothing precedes from', () {
      expect(Search.backward(fooBarFoo, 0, 'foo'), const SearchHit(8, 11));
    });

    test('clamps an out-of-range from', () {
      expect(Search.backward(fooBarFoo, 999, 'foo'), const SearchHit(8, 11));
      expect(Search.backward(fooBarFoo, -5, 'foo'), const SearchHit(8, 11));
    });

    test('repeated backward walks hits in reverse then wraps', () {
      final SearchHit a = Search.backward(fooBarFoo, 11, 'foo')!;
      expect(a, const SearchHit(8, 11));
      final SearchHit b = Search.backward(fooBarFoo, a.start, 'foo')!;
      expect(b, const SearchHit(0, 3));
      final SearchHit c = Search.backward(fooBarFoo, b.start, 'foo')!;
      expect(c, const SearchHit(8, 11)); // wrapped
    });

    test('folds case for a lower-case needle', () {
      expect(Search.backward('HELLOxx', 7, 'hello'), const SearchHit(0, 5));
      expect(Search.backward('HELLOxx', 7, 'Hello'), isNull);
    });

    test('null on no match and on an empty needle', () {
      expect(Search.backward(fooBarFoo, 11, 'zz'), isNull);
      expect(Search.backward(fooBarFoo, 11, ''), isNull);
    });
  });

  group('replaceNext', () {
    test('replaces the hit at from and parks the caret after it', () {
      final r = Search.replaceNext(fooBarFoo, 0, 'foo', 'baz')!;
      expect(r.text, 'baz bar foo');
      expect(r.caret, 3);
    });

    test('replaces the first hit at/after from', () {
      final r = Search.replaceNext(fooBarFoo, 1, 'foo', 'baz')!;
      expect(r.text, 'foo bar baz');
      expect(r.caret, 11);
    });

    test('caret follows a longer replacement', () {
      final r = Search.replaceNext('aaa', 0, 'a', 'xyz')!;
      expect(r.text, 'xyzaa');
      expect(r.caret, 3);
    });

    test('caret follows a shorter / empty replacement', () {
      final r = Search.replaceNext('foo bar', 0, 'foo', '')!;
      expect(r.text, ' bar');
      expect(r.caret, 0);
    });

    test('does not wrap — null when no match at/after from', () {
      expect(Search.replaceNext(fooBarFoo, 9, 'foo', 'baz'), isNull);
    });

    test('folds case and replaces the differently-cased hit', () {
      final r = Search.replaceNext('xx HELLO', 0, 'hello', 'hi')!;
      expect(r.text, 'xx hi');
      expect(r.caret, 5);
    });

    test('null on no match and on an empty needle', () {
      expect(Search.replaceNext(fooBarFoo, 0, 'zz', 'x'), isNull);
      expect(Search.replaceNext(fooBarFoo, 0, '', 'x'), isNull);
    });
  });

  group('replaceAll', () {
    test('replaces every hit and counts them', () {
      final r = Search.replaceAll(fooBarFoo, 'foo', 'baz');
      expect(r.text, 'baz bar baz');
      expect(r.count, 2);
    });

    test('folds case for a lower-case needle', () {
      final r = Search.replaceAll('Foo foo FOO', 'foo', 'x');
      expect(r.text, 'x x x');
      expect(r.count, 3);
    });

    test('an upper-cased needle replaces only exact-case hits', () {
      final r = Search.replaceAll('Foo foo FOO', 'Foo', 'x');
      expect(r.text, 'x foo FOO');
      expect(r.count, 1);
    });

    test('never re-scans the replacement text', () {
      final r = Search.replaceAll('aa', 'a', 'aa');
      expect(r.text, 'aaaa');
      expect(r.count, 2);
    });

    test('uses the non-overlapping enumeration', () {
      expect(Search.replaceAll('aaaa', 'aa', 'b'), (text: 'bb', count: 2));
      expect(Search.replaceAll('aaa', 'aa', 'b'), (text: 'ba', count: 1));
    });

    test('an empty replacement deletes the hits', () {
      final r = Search.replaceAll('a-b-c', '-', '');
      expect(r.text, 'abc');
      expect(r.count, 2);
    });

    test('no match / empty needle -> text unchanged, count 0', () {
      expect(
          Search.replaceAll(fooBarFoo, 'zz', 'x'), (text: fooBarFoo, count: 0));
      expect(
          Search.replaceAll(fooBarFoo, '', 'x'), (text: fooBarFoo, count: 0));
    });
  });

  group('occur', () {
    // line 1 'foo'      offsets  0..2   ('\n' @3)
    // line 2 'bar'      offsets  4..6   ('\n' @7)
    // line 3 'foo foo'  offsets  8..14  ('\n' @15)
    // line 4 'baz'      offsets 16..18
    const String doc = 'foo\nbar\nfoo foo\nbaz';

    test('lists matching lines 1-indexed with their text', () {
      expect(Search.occur(doc, 'foo'), <({int line, String text})>[
        (line: 1, text: 'foo'),
        (line: 3, text: 'foo foo'),
      ]);
    });

    test('a line with several matches is listed once', () {
      expect(Search.occur('foo foo foo', 'foo'),
          <({int line, String text})>[(line: 1, text: 'foo foo foo')]);
    });

    test('reports the last line when the text has no trailing newline', () {
      expect(Search.occur(doc, 'baz'),
          <({int line, String text})>[(line: 4, text: 'baz')]);
    });

    test('a trailing newline does not invent an extra line', () {
      expect(Search.occur('foo\n', 'foo'),
          <({int line, String text})>[(line: 1, text: 'foo')]);
    });

    test('counts blank lines when numbering', () {
      expect(Search.occur('\n\nfoo', 'foo'),
          <({int line, String text})>[(line: 3, text: 'foo')]);
    });

    test('a match spanning a newline is attributed to its starting line', () {
      expect(Search.occur('ab\ncd', 'b\nc'),
          <({int line, String text})>[(line: 1, text: 'ab')]);
    });

    test('folds case for a lower-case needle', () {
      expect(Search.occur('FOO\nbar', 'foo'),
          <({int line, String text})>[(line: 1, text: 'FOO')]);
    });

    test('no match / empty needle -> empty list', () {
      expect(Search.occur(doc, 'zz'), isEmpty);
      expect(Search.occur(doc, ''), isEmpty);
    });
  });

  group('SearchHit', () {
    test('value equality and span', () {
      expect(const SearchHit(1, 4), const SearchHit(1, 4));
      expect(const SearchHit(1, 4).hashCode, const SearchHit(1, 4).hashCode);
      expect(const SearchHit(1, 4) == const SearchHit(1, 5), isFalse);
      final SearchHit h = Search.forward('xxfoo', 0, 'foo')!;
      expect(h.end - h.start, 'foo'.length);
    });
  });
}
