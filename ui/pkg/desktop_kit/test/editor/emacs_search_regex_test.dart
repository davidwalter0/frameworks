// Thorough headless tests for RegexSearch (regex-flavoured search/replace)
// and QueryReplaceSession (stepwise interactive query-replace over either
// engine). Offsets below are hand-counted from the literal test strings.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RegexSearch.compile / errorFor', () {
    test('compiles a valid pattern', () {
      final RegexCompileResult r = RegexSearch.compile(r'fo+');
      expect(r.ok, isTrue);
      expect(r.error, isNull);
      expect(RegexSearch.errorFor(r'fo+'), isNull);
    });

    test('an unbalanced group surfaces a clean error string, never throws', () {
      expect(
        () => RegexSearch.errorFor('fo('),
        returnsNormally,
      );
      final String? err = RegexSearch.errorFor('fo(');
      expect(err, isNotNull);
      expect(err, contains('Invalid regexp'));
    });

    test('empty pattern compiles to a null regex with no error', () {
      final RegexCompileResult r = RegexSearch.compile('');
      expect(r.ok, isFalse);
      expect(r.error, isNull);
    });
  });

  group('RegexSearch.matches', () {
    test('finds every non-overlapping regex hit, left to right', () {
      // 'foo1 foo22 foo333' -> foo1@[0,4), foo22@[5,10), foo333@[11,17)
      expect(
        RegexSearch.matches('foo1 foo22 foo333', r'foo\d+'),
        const <SearchHit>[
          SearchHit(0, 4),
          SearchHit(5, 10),
          SearchHit(11, 17),
        ],
      );
    });

    test('an all-lower-case pattern folds case (mirrors Search)', () {
      expect(
        RegexSearch.matches('Hello hello HELLO', r'hel+o'),
        const <SearchHit>[SearchHit(0, 5), SearchHit(6, 11), SearchHit(12, 17)],
      );
    });

    test('any upper-case in the pattern forces case-sensitive matching', () {
      expect(
        RegexSearch.matches('Hello hello HELLO', r'Hel+o'),
        const <SearchHit>[SearchHit(0, 5)],
      );
    });

    test('an invalid pattern reports no matches instead of throwing', () {
      expect(RegexSearch.matches('foo bar', 'fo('), isEmpty);
    });

    test('zero-width matches are skipped so scans terminate', () {
      // 'abc' against 'x*' would loop forever if zero-width hits weren't
      // skipped; expect no hits (no literal 'x' present).
      expect(RegexSearch.matches('abc', 'x*'), isEmpty);
    });
  });

  group('RegexSearch.forward / backward (wrapping)', () {
    // 'foo1 bar foo22 baz'
    //  0123456789...
    const String text = 'foo1 bar foo22 baz';

    test('forward finds the next hit at/after the offset', () {
      expect(RegexSearch.forward(text, 0, r'foo\d+'), const SearchHit(0, 4));
      expect(RegexSearch.forward(text, 5, r'foo\d+'), const SearchHit(9, 14));
    });

    test('forward wraps to the start when nothing remains ahead', () {
      expect(RegexSearch.forward(text, 15, r'foo\d+'), const SearchHit(0, 4));
    });

    test('backward finds the previous hit strictly before the offset', () {
      expect(
        RegexSearch.backward(text, text.length, r'foo\d+'),
        const SearchHit(9, 14),
      );
      expect(RegexSearch.backward(text, 9, r'foo\d+'), const SearchHit(0, 4));
    });

    test('backward wraps to the end when nothing remains behind', () {
      expect(RegexSearch.backward(text, 0, r'foo\d+'), const SearchHit(9, 14));
    });

    test('invalid pattern returns null instead of throwing, both directions',
        () {
      expect(RegexSearch.forward(text, 0, 'fo('), isNull);
      expect(RegexSearch.backward(text, 0, 'fo('), isNull);
    });
  });

  group('RegexSearch.replaceNext / replaceAll', () {
    test('replaceNext replaces the first match at/after the offset', () {
      final result =
          RegexSearch.replaceNext('foo1 foo22 foo333', 0, r'foo\d+', 'X');
      expect(result, isNotNull);
      expect(result!.text, 'X foo22 foo333');
      expect(result.caret, 1);
    });

    test('replaceNext does not wrap: null when nothing matches ahead', () {
      final result =
          RegexSearch.replaceNext('foo1 foo22 foo333', 11, r'foo1\b', 'X');
      expect(result, isNull);
    });

    test('replaceAll replaces every match and reports the count', () {
      final result =
          RegexSearch.replaceAll('foo1 foo22 foo333', r'foo\d+', 'X');
      expect(result.text, 'X X X');
      expect(result.count, 3);
    });

    test('capture-group substitution: \$1 refs the first group', () {
      final result = RegexSearch.replaceAll(
        'John Smith, Jane Doe',
        r'(\w+) (\w+)',
        r'$2 $1',
      );
      expect(result.text, 'Smith John, Doe Jane');
      expect(result.count, 2);
    });

    test(r'$& refs the whole match and $$ is a literal dollar sign', () {
      final result = RegexSearch.replaceAll('foo', r'foo', r'[$&=$$5]');
      expect(result.text, '[foo=\$5]');
    });

    test('a group ref for a group that did not participate is empty', () {
      final result = RegexSearch.replaceAll('foo', r'(foo)|(bar)', r'<$1|$2>');
      expect(result.text, '<foo|>');
    });

    test('invalid pattern leaves text untouched with a zero count', () {
      final result = RegexSearch.replaceAll('foo bar', 'fo(', 'X');
      expect(result.text, 'foo bar');
      expect(result.count, 0);
    });
  });

  group('QueryReplaceSession — literal mode (y/n/!)', () {
    test('walks forward, replacing on "y" (replaceCurrent)', () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar foo baz foo', 0, 'foo', 'X');
      expect(s.done, isFalse);
      expect(s.current, const SearchHit(0, 3));

      s.replaceCurrent(); // y
      expect(s.text, 'X bar foo baz foo');
      expect(s.replacedCount, 1);
      expect(s.current, const SearchHit(6, 9));

      s.replaceCurrent(); // y
      expect(s.text, 'X bar X baz foo');
      expect(s.current, const SearchHit(12, 15));

      s.replaceCurrent(); // y
      expect(s.text, 'X bar X baz X');
      expect(s.replacedCount, 3);
      expect(s.done, isTrue);
      expect(s.quitRequested, isFalse);
    });

    test('"n" (skip) leaves text untouched and advances past the match', () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar foo baz foo', 0, 'foo', 'X');
      s.skip(); // n on hit @0
      expect(s.text, 'foo bar foo baz foo');
      expect(s.replacedCount, 0);
      expect(s.current, const SearchHit(8, 11));

      s.replaceCurrent(); // y on hit @8
      expect(s.text, 'foo bar X baz foo');
      expect(s.current, const SearchHit(14, 17));
    });

    test('"!" (replaceAll) replaces the current and every remaining match', () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar foo baz foo', 0, 'foo', 'X');
      s.replaceAll(); // !
      expect(s.text, 'X bar X baz X');
      expect(s.replacedCount, 3);
      expect(s.done, isTrue);
    });

    test('"q" (quit) stops immediately without touching the current match', () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar foo baz foo', 0, 'foo', 'X');
      s.quit(); // q on hit @0
      expect(s.text, 'foo bar foo baz foo');
      expect(s.replacedCount, 0);
      expect(s.done, isTrue);
      expect(s.quitRequested, isTrue);
      expect(s.current, isNull);
    });

    test('does not wrap: session is done when no match remains ahead', () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar', 4, 'foo', 'X');
      expect(s.done, isTrue);
      expect(s.current, isNull);
    });

    test('further replaceCurrent/skip calls after done are no-ops', () {
      final QueryReplaceSession s = QueryReplaceSession('foo', 0, 'foo', 'X');
      s.replaceCurrent();
      expect(s.done, isTrue);
      s.replaceCurrent();
      s.skip();
      expect(s.text, 'X');
      expect(s.replacedCount, 1);
    });
  });

  group('QueryReplaceSession — regex mode', () {
    test('regex: true drives matches through RegexSearch', () {
      final QueryReplaceSession s = QueryReplaceSession(
        'foo1 foo22 foo333',
        0,
        r'foo\d+',
        'X',
        regex: true,
      );
      expect(s.current, const SearchHit(0, 4));
      s.replaceCurrent();
      expect(s.text, 'X foo22 foo333');
      expect(s.current, const SearchHit(2, 7));
      s.replaceAll();
      expect(s.text, 'X X X');
      expect(s.replacedCount, 3);
    });

    test('capture-group substitution applies per accepted replacement', () {
      final QueryReplaceSession s = QueryReplaceSession(
        'John Smith, Jane Doe',
        0,
        r'(\w+) (\w+)',
        r'$2 $1',
        regex: true,
      );
      s.replaceCurrent();
      expect(s.text, 'Smith John, Jane Doe');
      s.replaceCurrent();
      expect(s.text, 'Smith John, Doe Jane');
      expect(s.done, isTrue);
    });

    test('skip on a regex match advances past it without replacing', () {
      final QueryReplaceSession s = QueryReplaceSession(
        'foo1 foo22 foo333',
        0,
        r'foo\d+',
        'X',
        regex: true,
      );
      s.skip();
      expect(s.text, 'foo1 foo22 foo333');
      expect(s.current, const SearchHit(5, 10));
    });

    test('an invalid regex pattern surfaces via error and the session is done',
        () {
      final QueryReplaceSession s =
          QueryReplaceSession('foo bar', 0, 'fo(', 'X', regex: true);
      expect(s.done, isTrue);
      expect(s.current, isNull);
      expect(s.error, isNotNull);
      expect(s.error, contains('Invalid regexp'));
      expect(s.replacedCount, 0);
    });

    test('regex case-folding: all-lower pattern matches mixed case', () {
      final QueryReplaceSession s = QueryReplaceSession(
        'Hello hello HELLO',
        0,
        r'hel+o',
        'X',
        regex: true,
      );
      s.replaceAll();
      expect(s.text, 'X X X');
      expect(s.replacedCount, 3);
    });
  });
}
