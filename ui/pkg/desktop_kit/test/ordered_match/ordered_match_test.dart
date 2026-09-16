// Ordered subsequence matching: whitespace components must appear left to
// right; top-level `|` gives alternative orderings; components are regexps.
// The user's vault example is the acceptance case.
import 'package:desktop_kit/desktop_kit_ordered_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the vault example', () {
    const String cand = 'vault-secret-approle';

    test('"v sec ap" matches (left-to-right subsequence)', () {
      expect(orderedMatch(cand, 'v sec ap'), isTrue);
    });

    test('"approle vault secret" does NOT (present but out of order)', () {
      expect(orderedMatch(cand, 'approle vault secret'), isFalse);
    });

    test('"v sec ap|ap v sec" matches via its first branch', () {
      expect(orderedMatch(cand, 'v sec ap|ap v sec'), isTrue);
    });

    test('an alternative whose order fits matches even if the first does not',
        () {
      // Branch 2 "vault secret approle" IS in order -> matches.
      expect(orderedMatch(cand, 'secret approle vault|vault secret approle'),
          isTrue);
      // Both branches out of order -> no match.
      expect(orderedMatch(cand, 'approle secret vault|secret vault approle'),
          isFalse);
    });
  });

  group('semantics', () {
    test('single component is a plain (ordered-trivial) substring / regexp',
        () {
      expect(orderedMatch('vault-secret-approle', 'secret'), isTrue);
      expect(orderedMatch('vault-secret-approle', 'v.*ap'), isTrue);
      expect(orderedMatch('vault-secret-approle', 'zzz'), isFalse);
    });

    test('empty / blank / all-pipe query matches everything', () {
      expect(orderedMatch('anything', ''), isTrue);
      expect(orderedMatch('anything', '   '), isTrue);
      expect(orderedMatch('anything', '|'), isTrue);
    });

    test('regexp components: digits and classes', () {
      expect(orderedMatch('file_v2_final', r'file \d final'), isTrue);
      expect(orderedMatch('file_final', r'file \d final'), isFalse);
    });

    test('smart case: lowercase is case-insensitive, an uppercase is exact',
        () {
      expect(orderedMatch('VaultSecret', 'vault secret'), isTrue);
      expect(orderedMatch('VaultSecret', 'Vault Secret'), isTrue);
      expect(orderedMatch('vaultsecret', 'Vault'), isFalse);
    });

    test('caseSensitive: false forces case-insensitive (filename completion)',
        () {
      // Smart-case would make an uppercase query exact; the override ignores
      // case entirely, so README matches readme and vice versa.
      expect(
          orderedMatch('readme.org', 'README', caseSensitive: false), isTrue);
      expect(
          orderedMatch('README.org', 'readme', caseSensitive: false), isTrue);
      expect(
          orderedMatch('README.org', 'ReAdMe', caseSensitive: false), isTrue);
      // Sanity: without the override, uppercase 'README' is exact and misses.
      expect(orderedMatch('readme.org', 'README'), isFalse);
    });

    test('a half-typed invalid regexp component matches literally', () {
      // "a[" is not a valid regexp -> literal; ordered with "b".
      expect(orderedMatch('xa[yb', 'a[ b'), isTrue);
      expect(orderedMatch('xbya[', 'a[ b'), isFalse); // out of order
    });

    test('literal dashes in a component (a-b) match as text, in order', () {
      expect(orderedMatch('x-a-b-y', 'a-b'), isTrue);
      expect(orderedMatch('a-only', 'a-b'), isFalse);
    });
  });

  group('orderedRank', () {
    test('earlier first-component start sorts before a later one', () {
      final ({int at, int len, String s}) early = orderedRank('vault-x', 'v x');
      final ({int at, int len, String s}) later =
          orderedRank('zz-vault-x', 'v x');
      expect(early.at, lessThan(later.at));
    });
  });
}
