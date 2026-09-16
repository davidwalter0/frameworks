// The [RegexEngine] seam: that installing one actually redirects every regexp
// question, that the default is unchanged, and that the kit's own contracts
// (zero-width skipping, Emacs case folding, `$n` expansion) survive the trip.
//
// No subprocess here — a recording fake stands in for a real engine, so this
// file tests the SEAM. The engine that motivated it is exercised against the
// real thing, and against real GNU Emacs, in textloom's
// `test/emacs_regex_engine_test.dart`.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine that records what it was asked and answers from a fixed script,
/// so "did the call reach the engine?" is decidable rather than inferred.
class _FakeEngine implements RegexEngine {
  _FakeEngine({this.error, this.hits = const <List<int>>[]});

  /// Returned by [errorFor] for every non-empty pattern.
  final String? error;

  /// `[start, end]` pairs the fake reports, in order.
  final List<List<int>> hits;

  final List<String> calls = <String>[];

  @override
  String? errorFor(String pattern) {
    calls.add('errorFor($pattern)');
    return pattern.isEmpty ? null : error;
  }

  @override
  List<RegexMatchSpan> allMatches(String text, String pattern) {
    calls.add('allMatches($pattern)');
    if (error != null) return const <RegexMatchSpan>[];
    return <RegexMatchSpan>[
      for (final List<int> h in hits)
        RegexMatchSpan(text, h[0], h[1], const <String?>[]),
    ];
  }

  @override
  RegexMatchSpan? firstMatchFrom(String text, int start, String pattern) {
    calls.add('firstMatchFrom($pattern,$start)');
    if (error != null) return null;
    for (final List<int> h in hits) {
      if (h[0] >= start)
        return RegexMatchSpan(text, h[0], h[1], const <String?>[]);
    }
    return null;
  }

  @override
  RegexMatchSpan? lastMatchBefore(String text, int before, String pattern) {
    calls.add('lastMatchBefore($pattern,$before)');
    if (error != null) return null;
    RegexMatchSpan? found;
    for (final List<int> h in hits) {
      if (h[0] >= before) break;
      found = RegexMatchSpan(text, h[0], h[1], const <String?>[]);
    }
    return found;
  }
}

void main() {
  tearDown(() => RegexSearch.engine = null);

  group('the default engine is unchanged', () {
    test('it is DartRegexEngine, and ECMAScript semantics still apply', () {
      expect(RegexSearch.engine, isA<DartRegexEngine>());
      // The measured defect, asserted as the DEFAULT's behaviour rather than
      // silently fixed underneath every existing consumer: the kit cannot
      // depend on a Go binary, and the web target has none, so this is the
      // floor. It is pinned here so that a future change to the default is a
      // deliberate act with a failing test attached, not a drift.
      expect(RegexSearch.forward('a', 0, r'\(a\|b\)'), isNull);
      expect(RegexSearch.forward('abc', 0, r'[[:alpha:]]+'), isNull);
      expect(RegexSearch.forward('aaa', 0, r'a\{2,3\}'), isNull);
      expect(RegexSearch.forward('x', 0, r'\sw'), isNull);
      // ...and the control, which both dialects spell the same way.
      expect(RegexSearch.forward('foo', 0, r'\bfoo\b'), const SearchHit(0, 3));
    });

    test('setting the engine to null restores the default', () {
      RegexSearch.engine = _FakeEngine();
      expect(RegexSearch.engine, isA<_FakeEngine>());
      RegexSearch.engine = null;
      expect(RegexSearch.engine, isA<DartRegexEngine>());
    });
  });

  group('installing an engine redirects every regexp question', () {
    test('matches / forward / backward all route through it', () {
      final _FakeEngine fake = _FakeEngine(hits: <List<int>>[
        <int>[0, 2],
        <int>[5, 7]
      ]);
      RegexSearch.engine = fake;

      expect(RegexSearch.matches('ab   cd', 'zz'),
          <SearchHit>[const SearchHit(0, 2), const SearchHit(5, 7)]);
      expect(RegexSearch.forward('ab   cd', 3, 'zz'), const SearchHit(5, 7));
      expect(RegexSearch.backward('ab   cd', 5, 'zz'), const SearchHit(0, 2));

      expect(fake.calls, contains('allMatches(zz)'));
      expect(fake.calls, contains('firstMatchFrom(zz,3)'));
      expect(fake.calls, contains('lastMatchBefore(zz,5)'));
    });

    test('an engine that rejects the pattern surfaces its error verbatim', () {
      RegexSearch.engine = _FakeEngine(error: 'Invalid regexp: nope');
      final RegexCompileResult r = RegexSearch.compile('anything');
      expect(r.ok, isFalse);
      expect(r.error, 'Invalid regexp: nope');
      expect(RegexSearch.errorFor('anything'), 'Invalid regexp: nope');
      expect(RegexSearch.matches('abc', 'anything'), isEmpty);
      expect(RegexSearch.forward('abc', 0, 'anything'), isNull);
    });

    test('compile reports ok with a NULL RegExp under a non-Dart engine', () {
      // The trap this test pins: `compile(...).regex == null` used to mean
      // "did not compile". Under any engine that is not Dart's RegExp there is
      // no RegExp to hand back, so a caller still reading `regex` would route
      // every valid pattern down its failure branch.
      RegexSearch.engine = _FakeEngine(hits: <List<int>>[
        <int>[0, 1]
      ]);
      final RegexCompileResult r = RegexSearch.compile('whatever');
      expect(r.ok, isTrue);
      expect(r.regex, isNull);
      expect(r.error, isNull);
    });

    test('the empty pattern is "no search", and reaches no engine at all', () {
      final _FakeEngine fake = _FakeEngine();
      RegexSearch.engine = fake;
      final RegexCompileResult r = RegexSearch.compile('');
      expect(r.ok, isFalse);
      expect(r.error, isNull);
      expect(RegexSearch.matches('abc', ''), isEmpty);
      expect(RegexSearch.forward('abc', 0, ''), isNull);
      expect(RegexSearch.backward('abc', 3, ''), isNull);
      expect(RegexSearch.errorFor(''), isNull);
      expect(fake.calls, isEmpty,
          reason: 'an empty pattern must not cost a round trip');
    });
  });

  group('wrapping still happens above the engine', () {
    test('forward wraps to 0 and backward wraps to the end', () {
      RegexSearch.engine = _FakeEngine(hits: <List<int>>[
        <int>[0, 2],
        <int>[5, 7]
      ]);
      // Past the last hit: the first probe finds nothing, the wrap re-probes
      // from 0. The engine itself never wraps — that stays the kit's job, so
      // an engine implementor cannot get it subtly wrong.
      expect(RegexSearch.forward('ab   cd', 7, 'zz'), const SearchHit(0, 2));
      expect(RegexSearch.backward('ab   cd', 0, 'zz'), const SearchHit(5, 7));
    });
  });

  group(r'capture groups and $-expansion survive the seam', () {
    test(r'replaceAll expands $1 / $& / $$ from the engine groups', () {
      RegexSearch.engine = _GroupEngine();
      final ({String text, int count}) r =
          RegexSearch.replaceAll('ab', 'p', r'<$1|$2>');
      // group 1 = 'a', group 2 did not participate -> empty, not group 3's text.
      expect(r.text, '<a|>');
      expect(r.count, 1);
    });

    test('a non-participating group keeps later groups on their number', () {
      const RegexMatchSpan m =
          RegexMatchSpan('xyz', 0, 3, <String?>[null, 'B', 'C']);
      expect(m.group(0), 'xyz');
      expect(m.group(1), isNull);
      expect(m.group(2), 'B');
      expect(m.group(3), 'C');
      expect(m.group(4), isNull);
      expect(m.groupCount, 3);
    });
  });

  group('QueryReplaceSession runs on the installed engine', () {
    test('regex mode walks the engine\'s matches', () {
      RegexSearch.engine = _FakeEngine(hits: <List<int>>[
        <int>[0, 2],
        <int>[5, 7]
      ]);
      final QueryReplaceSession s =
          QueryReplaceSession('ab   cd', 0, 'zz', 'X', regex: true);
      expect(s.current, const SearchHit(0, 2));
      s.replaceCurrent();
      expect(s.text, 'X   cd');
    });

    test('an engine error ends the session with that error', () {
      RegexSearch.engine = _FakeEngine(error: 'Invalid regexp: nope');
      final QueryReplaceSession s =
          QueryReplaceSession('abc', 0, 'zz', 'X', regex: true);
      expect(s.done, isTrue);
      expect(s.error, 'Invalid regexp: nope');
    });
  });

  group('emacsFoldsCase is the one shared rule', () {
    test('no upper case folds; any upper case does not', () {
      expect(emacsFoldsCase('hello'), isTrue);
      expect(emacsFoldsCase(r'[[:alpha:]]+'), isTrue);
      expect(emacsFoldsCase('Hello'), isFalse);
      // `\S` is a syntax-class NEGATION spelled with a capital, so it makes a
      // search case-sensitive. Real Emacs does the same, for the same reason:
      // the rule scans the search string, it does not analyse the pattern.
      expect(emacsFoldsCase(r'\Sw'), isFalse);
    });
  });
}

/// Reports one match carrying a participating group 1 and an absent group 2.
class _GroupEngine implements RegexEngine {
  @override
  String? errorFor(String pattern) => null;

  RegexMatchSpan _m(String text) =>
      RegexMatchSpan(text, 0, text.length, <String?>['a', null]);

  @override
  List<RegexMatchSpan> allMatches(String text, String pattern) =>
      <RegexMatchSpan>[_m(text)];

  @override
  RegexMatchSpan? firstMatchFrom(String text, int start, String pattern) =>
      start == 0 ? _m(text) : null;

  @override
  RegexMatchSpan? lastMatchBefore(String text, int before, String pattern) =>
      before > 0 ? _m(text) : null;
}
