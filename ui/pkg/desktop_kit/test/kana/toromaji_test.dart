import 'package:desktop_kit/desktop_kit_kana.dart';
import 'package:flutter_test/flutter_test.dart';

/// Table-driven tests for [Kana.toRomaji]: kana → Hepburn romaji conversion.
///
/// Edge cases exercised:
///   * basic gojūon (all five vowels, k/g/s/z/t/d/n/h/b/p/m/y/r/w rows)
///   * Hepburn specials (し→shi, ち→chi, つ→tsu, ふ→fu, じ→ji)
///   * youon (compound kana: きゃ→kya, しゃ→sha, ちょ→cho, じゃ→ja)
///   * gemination (っ): がっこう→gakkou, きって→kitte; trailing っ→t
///   * ん disambiguation: しんよう→shin'you, さんあん→san'an; elsewhere ん→n
///   * katakana input: normalised to hiragana first (ニホンゴ→nihongo)
///   * pass-through: ASCII, digits, kanji, spaces, katakana long-vowel mark ー
void main() {
  group('Kana.toRomaji', () {
    // -------------------------------------------------------------------------
    // Empty input
    // -------------------------------------------------------------------------
    test('empty string → empty string', () {
      expect(Kana.toRomaji(''), '');
    });

    // -------------------------------------------------------------------------
    // Basic vowels
    // -------------------------------------------------------------------------
    group('vowels', () {
      const cases = <(String, String, String)>[
        ('あ→a', 'あ', 'a'),
        ('い→i', 'い', 'i'),
        ('う→u', 'う', 'u'),
        ('え→e', 'え', 'e'),
        ('お→o', 'お', 'o'),
        ('あいうえお→aiueo', 'あいうえお', 'aiueo'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.toRomaji(input), expected));
      }
    });

    // -------------------------------------------------------------------------
    // k / g rows
    // -------------------------------------------------------------------------
    group('k/g row', () {
      const cases = <(String, String, String)>[
        ('か→ka', 'か', 'ka'),
        ('き→ki', 'き', 'ki'),
        ('く→ku', 'く', 'ku'),
        ('け→ke', 'け', 'ke'),
        ('こ→ko', 'こ', 'ko'),
        ('が→ga', 'が', 'ga'),
        ('ぎ→gi', 'ぎ', 'gi'),
        ('ぐ→gu', 'ぐ', 'gu'),
        ('げ→ge', 'げ', 'ge'),
        ('ご→go', 'ご', 'go'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.toRomaji(input), expected));
      }
    });

    // -------------------------------------------------------------------------
    // Hepburn specials: し・ち・つ・ふ・じ
    // -------------------------------------------------------------------------
    group('Hepburn specials', () {
      const cases = <(String, String, String)>[
        ('し→shi', 'し', 'shi'),
        ('ち→chi', 'ち', 'chi'),
        ('つ→tsu', 'つ', 'tsu'),
        ('ふ→fu', 'ふ', 'fu'),
        ('じ→ji', 'じ', 'ji'),
        ('づ→zu (Hepburn maps づ→zu)', 'づ', 'zu'),
        ('を→o (particle wo)', 'を', 'o'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.toRomaji(input), expected));
      }
    });

    // -------------------------------------------------------------------------
    // Youon (compound kana = base + small y-kana)
    // -------------------------------------------------------------------------
    group('youon', () {
      const cases = <(String, String, String)>[
        ('きゃ→kya', 'きゃ', 'kya'),
        ('きゅ→kyu', 'きゅ', 'kyu'),
        ('きょ→kyo', 'きょ', 'kyo'),
        ('しゃ→sha', 'しゃ', 'sha'),
        ('しゅ→shu', 'しゅ', 'shu'),
        ('しょ→sho', 'しょ', 'sho'),
        ('ちゃ→cha', 'ちゃ', 'cha'),
        ('ちゅ→chu', 'ちゅ', 'chu'),
        ('ちょ→cho', 'ちょ', 'cho'),
        ('じゃ→ja', 'じゃ', 'ja'),
        ('じゅ→ju', 'じゅ', 'ju'),
        ('じょ→jo', 'じょ', 'jo'),
        ('にゃ→nya', 'にゃ', 'nya'),
        ('にゅ→nyu', 'にゅ', 'nyu'),
        ('にょ→nyo', 'にょ', 'nyo'),
        ('みょ→myo', 'みょ', 'myo'),
        ('りょ→ryo', 'りょ', 'ryo'),
        ('ひゃ→hya', 'ひゃ', 'hya'),
        ('びゃ→bya', 'びゃ', 'bya'),
        ('ぴょ→pyo', 'ぴょ', 'pyo'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.toRomaji(input), expected));
      }
    });

    // -------------------------------------------------------------------------
    // Gemination (っ → doubled leading consonant)
    // -------------------------------------------------------------------------
    group('gemination (っ)', () {
      test('がっこう→gakkou', () {
        expect(Kana.toRomaji('がっこう'), 'gakkou');
      });
      test('きって→kitte', () {
        expect(Kana.toRomaji('きって'), 'kitte');
      });
      test('ほっかいどう→hokkaidou', () {
        expect(Kana.toRomaji('ほっかいどう'), 'hokkaidou');
      });
      test('っか→kka (leading gemination)', () {
        expect(Kana.toRomaji('っか'), 'kka');
      });
      test('trailing っ → t (fallback)', () {
        expect(Kana.toRomaji('っ'), 't');
      });
      test('っしゃ→ssha (geminate before youon)', () {
        // っ + しゃ: leading consonant of "sha" is "s" → ss + ha would be
        // wrong; must double the "s" → ssha.
        expect(Kana.toRomaji('っしゃ'), 'ssha');
      });
    });

    // -------------------------------------------------------------------------
    // ん disambiguation
    // -------------------------------------------------------------------------
    group('ん disambiguation', () {
      test("しんよう→shin'you (ん before y)", () {
        expect(Kana.toRomaji('しんよう'), "shin'you");
      });
      test("さんあん→san'an (ん before vowel)", () {
        expect(Kana.toRomaji('さんあん'), "san'an");
      });
      test('しんぶん→shinbun (ん before consonant — no apostrophe)', () {
        expect(Kana.toRomaji('しんぶん'), 'shinbun');
      });
      test('にほん→nihon (trailing ん)', () {
        expect(Kana.toRomaji('にほん'), 'nihon');
      });
      test('おんがく→ongaku (ん before g — no apostrophe)', () {
        expect(Kana.toRomaji('おんがく'), 'ongaku');
      });
    });

    // -------------------------------------------------------------------------
    // Katakana input (normalised first)
    // -------------------------------------------------------------------------
    group('katakana input', () {
      test('ニホンゴ→nihongo', () {
        expect(Kana.toRomaji('ニホンゴ'), 'nihongo');
      });
      test('トウキョウ→toukyou', () {
        expect(Kana.toRomaji('トウキョウ'), 'toukyou');
      });
      test('ラーメン: ー passes through', () {
        // ラ→ra, ー→ー (pass-through), メ→me, ン→n
        expect(Kana.toRomaji('ラーメン'), 'raーmen');
      });
    });

    // -------------------------------------------------------------------------
    // Pass-through: ASCII / digits / kanji / punctuation
    // -------------------------------------------------------------------------
    group('pass-through characters', () {
      test('ASCII letters pass through', () {
        expect(Kana.toRomaji('hello'), 'hello');
      });
      test('digits pass through', () {
        expect(Kana.toRomaji('123'), '123');
      });
      test('kanji pass through', () {
        expect(Kana.toRomaji('漢字'), '漢字');
      });
      test('spaces pass through', () {
        expect(Kana.toRomaji('あ い'), 'a i');
      });
    });

    // -------------------------------------------------------------------------
    // Real-word integration cases
    // -------------------------------------------------------------------------
    group('real-word integration', () {
      const cases = <(String, String, String)>[
        ('あいうえお→aiueo', 'あいうえお', 'aiueo'),
        ('きゃ→kya', 'きゃ', 'kya'),
        ('がっこう→gakkou', 'がっこう', 'gakkou'),
        ('しんぶん→shinbun', 'しんぶん', 'shinbun'),
        ('ニホンゴ→nihongo', 'ニホンゴ', 'nihongo'),
        ('さくら→sakura', 'さくら', 'sakura'),
        ('ありがとう→arigatou', 'ありがとう', 'arigatou'),
        ('てんき→tenki', 'てんき', 'tenki'),
        ('なまえ→namae', 'なまえ', 'namae'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.toRomaji(input), expected));
      }
    });
  });
}
