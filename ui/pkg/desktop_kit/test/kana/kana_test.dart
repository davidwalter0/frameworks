import 'package:desktop_kit/desktop_kit_kana.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // hiraganaToKatakana
  // ---------------------------------------------------------------------------
  group('hiraganaToKatakana', () {
    const cases = <(String, String, String)>[
      // (description, input, expected)
      ('empty string', '', ''),
      ('single vowel あ', 'あ', 'ア'),
      ('five core vowels', 'あいうえお', 'アイウエオ'),
      ('small ya/yu/yo pass through correctly', 'ゃゅょ', 'ャュョ'),
      ('small tsu っ', 'っ', 'ッ'),
      ('compound きゃ', 'きゃ', 'キャ'),
      ('compound きゅ', 'きゅ', 'キュ'),
      ('compound きょ', 'きょ', 'キョ'),
      ('full hiragana word こんにちは', 'こんにちは', 'コンニチハ'),
      ('ASCII unchanged', 'abc', 'abc'),
      ('kanji unchanged', '漢字', '漢字'),
      ('punctuation unchanged', '。、！', '。、！'),
      ('long-vowel mark ー unchanged', 'ー', 'ー'),
      ('half-width katakana unchanged', 'ｶﾅ', 'ｶﾅ'),
      ('mixed hiragana + kanji + ascii', 'てすと123', 'テスト123'),
      ('voiced sound わ→ワ', 'わ', 'ワ'),
      ('voiced sound ゑ→ヱ', 'ゑ', 'ヱ'),
      ('voiced sound を→ヲ', 'を', 'ヲ'),
      ('ん→ン', 'ん', 'ン'),
    ];

    for (final (desc, input, expected) in cases) {
      test(desc, () {
        expect(Kana.hiraganaToKatakana(input), expected);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // katakanaToHiragana
  // ---------------------------------------------------------------------------
  group('katakanaToHiragana', () {
    const cases = <(String, String, String)>[
      ('empty string', '', ''),
      ('single vowel ア', 'ア', 'あ'),
      ('five core vowels', 'アイウエオ', 'あいうえお'),
      ('small ャュョ', 'ャュョ', 'ゃゅょ'),
      ('small tsu ッ', 'ッ', 'っ'),
      ('compound キャ', 'キャ', 'きゃ'),
      ('full word コンニチハ', 'コンニチハ', 'こんにちは'),
      ('ASCII unchanged', 'abc', 'abc'),
      ('kanji unchanged', '漢字', '漢字'),
      // Katakana-only marks must pass through
      ('long-vowel mark ー unchanged', 'ー', 'ー'),
      ('middle dot ・ unchanged', '・', '・'),
      ('katakana iteration ヽ unchanged', 'ヽ', 'ヽ'),
      ('half-width katakana unchanged', 'ｶﾅ', 'ｶﾅ'),
      ('mixed katakana + kanji', 'テスト漢字', 'てすと漢字'),
      ('ン→ん', 'ン', 'ん'),
      ('ヲ→を', 'ヲ', 'を'),
    ];

    for (final (desc, input, expected) in cases) {
      test(desc, () {
        expect(Kana.katakanaToHiragana(input), expected);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Round-trips: hiragana → katakana → hiragana
  // ---------------------------------------------------------------------------
  group('hiragana↔katakana round-trips', () {
    const roundTripCases = <(String, String)>[
      ('vowels', 'あいうえお'),
      ('compound きゃ', 'きゃ'),
      ('small tsu + ka', 'っか'),
      ('full phrase こんにちは', 'こんにちは'),
      ('ん alone', 'ん'),
      ('を alone', 'を'),
    ];

    for (final (desc, hiragana) in roundTripCases) {
      test('round-trip $desc', () {
        final kata = Kana.hiraganaToKatakana(hiragana);
        final back = Kana.katakanaToHiragana(kata);
        expect(back, hiragana);
      });
    }

    test('non-kana characters survive round-trip unchanged', () {
      const mixed = 'abc漢字123。';
      expect(Kana.katakanaToHiragana(Kana.hiraganaToKatakana(mixed)), mixed);
    });
  });

  // ---------------------------------------------------------------------------
  // toggleKana
  // ---------------------------------------------------------------------------
  group('toggleKana', () {
    test('flips hiragana → katakana', () {
      expect(Kana.toggleKana('きょう'), 'キョウ');
    });

    test('flips katakana → hiragana', () {
      expect(Kana.toggleKana('キョウ'), 'きょう');
    });

    test('flips each kana in mixed text, leaving kanji/ASCII untouched', () {
      expect(Kana.toggleKana('あ漢ア'), 'ア漢あ');
      expect(Kana.toggleKana('カタ카な123abc'), 'かた카ナ123abc');
    });

    test('is an involution — applying twice returns the original', () {
      for (final s in const <String>[
        'あいうえお',
        'キョウ',
        'こんにちは世界',
        'ミックスmix漢字',
        '',
      ]) {
        expect(Kana.toggleKana(Kana.toggleKana(s)), s);
      }
    });

    test('long-vowel mark ー and kanji pass through', () {
      expect(Kana.toggleKana('ラーメン'), 'らーめん');
    });
  });

  // ---------------------------------------------------------------------------
  // containsKana / toggleRomajiKana
  // ---------------------------------------------------------------------------
  group('containsKana', () {
    test('true for hiragana / katakana, false for romaji + kanji', () {
      expect(Kana.containsKana('にほん'), isTrue);
      expect(Kana.containsKana('ニホン'), isTrue);
      expect(Kana.containsKana('nihon'), isFalse);
      expect(Kana.containsKana('日本'), isFalse); // kanji are not kana
      expect(Kana.containsKana(''), isFalse);
    });
  });

  group('toggleRomajiKana', () {
    test('romaji → hiragana', () {
      expect(Kana.toggleRomajiKana('nihon'), 'にほん');
    });
    test('hiragana → romaji', () {
      expect(Kana.toggleRomajiKana('にほん'), 'nihon');
    });
    test('katakana → romaji', () {
      expect(Kana.toggleRomajiKana('ニホン'), 'nihon');
    });
    test('romaji→kana→romaji round-trips (lands on hiragana in between)', () {
      expect(Kana.toggleRomajiKana(Kana.toggleRomajiKana('nihon')), 'nihon');
    });
  });

  // ---------------------------------------------------------------------------
  // romajiToHiragana
  // ---------------------------------------------------------------------------
  group('romajiToHiragana', () {
    // --- vowels ---------------------------------------------------------------
    group('vowels', () {
      const cases = <(String, String, String)>[
        ('a', 'a', 'あ'),
        ('i', 'i', 'い'),
        ('u', 'u', 'う'),
        ('e', 'e', 'え'),
        ('o', 'o', 'お'),
        ('aiueo', 'aiueo', 'あいうえお'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- k/g rows -------------------------------------------------------------
    group('k/g row', () {
      const cases = <(String, String, String)>[
        ('ka', 'ka', 'か'),
        ('ki', 'ki', 'き'),
        ('ku', 'ku', 'く'),
        ('ke', 'ke', 'け'),
        ('ko', 'ko', 'こ'),
        ('ga', 'ga', 'が'),
        ('gi', 'gi', 'ぎ'),
        ('gu', 'gu', 'ぐ'),
        ('ge', 'ge', 'げ'),
        ('go', 'go', 'ご'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- s/z rows -------------------------------------------------------------
    group('s/z row', () {
      const cases = <(String, String, String)>[
        ('sa', 'sa', 'さ'),
        ('shi', 'shi', 'し'),
        ('sha', 'sha', 'しゃ'),
        ('shu', 'shu', 'しゅ'),
        ('sho', 'sho', 'しょ'),
        ('su', 'su', 'す'),
        ('se', 'se', 'せ'),
        ('so', 'so', 'そ'),
        ('za', 'za', 'ざ'),
        ('ji (zi)', 'zi', 'じ'),
        ('zu', 'zu', 'ず'),
        ('ze', 'ze', 'ぜ'),
        ('zo', 'zo', 'ぞ'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- t/d rows (chi/tsu/fu/ji special spellings) --------------------------
    group('t/d row + chi/tsu/fu/ji', () {
      const cases = <(String, String, String)>[
        ('ta', 'ta', 'た'),
        ('chi', 'chi', 'ち'),
        ('cha', 'cha', 'ちゃ'),
        ('chu', 'chu', 'ちゅ'),
        ('cho', 'cho', 'ちょ'),
        ('tsu', 'tsu', 'つ'),
        ('te', 'te', 'て'),
        ('to', 'to', 'と'),
        ('da', 'da', 'だ'),
        ('de', 'de', 'で'),
        ('do', 'do', 'ど'),
        ('fu', 'fu', 'ふ'),
        ('ji', 'ji', 'じ'),
        ('ja', 'ja', 'じゃ'),
        ('ju', 'ju', 'じゅ'),
        ('jo', 'jo', 'じょ'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- n/h/b/p rows --------------------------------------------------------
    group('n/h/b/p rows', () {
      const cases = <(String, String, String)>[
        ('na', 'na', 'な'),
        ('ni', 'ni', 'に'),
        ('nu', 'nu', 'ぬ'),
        ('ne', 'ne', 'ね'),
        ('no', 'no', 'の'),
        ('ha', 'ha', 'は'),
        ('hi', 'hi', 'ひ'),
        ('hu = fu', 'hu', 'ふ'),
        ('he', 'he', 'へ'),
        ('ho', 'ho', 'ほ'),
        ('ba', 'ba', 'ば'),
        ('bi', 'bi', 'び'),
        ('bu', 'bu', 'ぶ'),
        ('be', 'be', 'べ'),
        ('bo', 'bo', 'ぼ'),
        ('pa', 'pa', 'ぱ'),
        ('pi', 'pi', 'ぴ'),
        ('pu', 'pu', 'ぷ'),
        ('pe', 'pe', 'ぺ'),
        ('po', 'po', 'ぽ'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- m/y/r/w rows --------------------------------------------------------
    group('m/y/r/w rows', () {
      const cases = <(String, String, String)>[
        ('ma', 'ma', 'ま'),
        ('mi', 'mi', 'み'),
        ('mu', 'mu', 'む'),
        ('me', 'me', 'め'),
        ('mo', 'mo', 'も'),
        ('ya', 'ya', 'や'),
        ('yu', 'yu', 'ゆ'),
        ('yo', 'yo', 'よ'),
        ('ra', 'ra', 'ら'),
        ('ri', 'ri', 'り'),
        ('ru', 'ru', 'る'),
        ('re', 're', 'れ'),
        ('ro', 'ro', 'ろ'),
        ('wa', 'wa', 'わ'),
        ('wo', 'wo', 'を'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- youon (compound kana) -----------------------------------------------
    group('youon (compound kana)', () {
      const cases = <(String, String, String)>[
        ('kya', 'kya', 'きゃ'),
        ('kyu', 'kyu', 'きゅ'),
        ('kyo', 'kyo', 'きょ'),
        ('gya', 'gya', 'ぎゃ'),
        ('gyo', 'gyo', 'ぎょ'),
        ('nya', 'nya', 'にゃ'),
        ('nyu', 'nyu', 'にゅ'),
        ('nyo', 'nyo', 'にょ'),
        ('hya', 'hya', 'ひゃ'),
        ('hyu', 'hyu', 'ひゅ'),
        ('hyo', 'hyo', 'ひょ'),
        ('bya', 'bya', 'びゃ'),
        ('byo', 'byo', 'びょ'),
        ('pya', 'pya', 'ぴゃ'),
        ('pyo', 'pyo', 'ぴょ'),
        ('mya', 'mya', 'みゃ'),
        ('myo', 'myo', 'みょ'),
        ('rya', 'rya', 'りゃ'),
        ('ryo', 'ryo', 'りょ'),
        ('sha', 'sha', 'しゃ'),
        ('shu', 'shu', 'しゅ'),
        ('sho', 'sho', 'しょ'),
        ('cha', 'cha', 'ちゃ'),
        ('chu', 'chu', 'ちゅ'),
        ('cho', 'cho', 'ちょ'),
        ('jya', 'jya', 'じゃ'),
        ('jyo', 'jyo', 'じょ'),
        ('kyou (きょう)', 'kyou', 'きょう'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- gemination (small tsu っ) -------------------------------------------
    group('gemination', () {
      const cases = <(String, String, String)>[
        ('kka → っか', 'kka', 'っか'),
        ('tta → った', 'tta', 'った'),
        ('kitto → きっと', 'kitto', 'きっと'),
        ('gakkou → がっこう', 'gakkou', 'がっこう'),
        ('chotto → ちょっと', 'chotto', 'ちょっと'),
        ('ssa → っさ', 'ssa', 'っさ'),
        ('ppa → っぱ', 'ppa', 'っぱ'),
        ('rippa → りっぱ', 'rippa', 'りっぱ'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });

    // --- n / nn handling -----------------------------------------------------
    group('n and nn handling', () {
      test('trailing lone n → ん', () {
        expect(Kana.romajiToHiragana('n'), 'ん');
      });

      test('nn → ん', () {
        expect(Kana.romajiToHiragana('nn'), 'ん');
      });

      test('n before consonant → ん', () {
        // 'nk' → ん + k (k not followed by vowel passes through)
        expect(Kana.romajiToHiragana('nk'), 'んk');
      });

      test('n before vowel → な row (not ん)', () {
        expect(Kana.romajiToHiragana('na'), 'な');
        expect(Kana.romajiToHiragana('ni'), 'に');
      });

      test('konnichiwa → こんにちわ', () {
        // k-o-n-n(standalone before n+i) -ni-chi-wa
        // Note: the historical Japanese spelling is こんにちは (ha used as wa),
        // but romaji→kana conversion maps 'wa'→わ, yielding こんにちわ.
        expect(Kana.romajiToHiragana('konnichiwa'), 'こんにちわ');
      });

      test('shinbun → しんぶん', () {
        // sh-i-n-b-u-n
        expect(Kana.romajiToHiragana('shinbun'), 'しんぶん');
      });

      test('anna → あんな (n before n+vowel cluster)', () {
        // a + n(standalone: next='n', next2='a'∈vowels) + na → あんな
        expect(Kana.romajiToHiragana('anna'), 'あんな');
      });
    });

    // --- ASCII / non-romaji pass-through -------------------------------------
    group('ascii and non-romaji pass-through', () {
      test('pure digits pass through', () {
        expect(Kana.romajiToHiragana('123'), '123');
      });

      test('spaces, commas, exclamation pass through when not romaji', () {
        // Pure punctuation/whitespace: no romaji keys match.
        expect(Kana.romajiToHiragana('  , ! ? .'), '  , ! ? .');
      });

      test('upper-case letters pass through (no table hit)', () {
        // 'XYZ' does not match any romaji key; passes through verbatim.
        expect(Kana.romajiToHiragana('XYZ'), 'XYZ');
      });

      test('empty string → empty string', () {
        expect(Kana.romajiToHiragana(''), '');
      });

      test('mixed romaji + kanji + spaces', () {
        // kanji is non-ASCII; romaji parts convert; spaces pass through.
        expect(Kana.romajiToHiragana('watashi wa 私'), 'わたし わ 私');
      });

      test('already-hiragana passes through unchanged', () {
        // Non-ASCII non-romaji code units are not in the table.
        expect(Kana.romajiToHiragana('あいう'), 'あいう');
      });
    });

    // --- real-word integration -----------------------------------------------
    group('real-word integration', () {
      const cases = <(String, String, String)>[
        ('arigatou gozaimasu', 'arigatou gozaimasu', 'ありがとう ございます'),
        ('sakura', 'sakura', 'さくら'),
        ('tokyo', 'tokyo', 'ときょ'),
        ('nihon', 'nihon', 'にほん'),
        ('sushi', 'sushi', 'すし'),
        ('ramen', 'ramen', 'らめん'),
        ('manga', 'manga', 'まんが'),
        ('anime', 'anime', 'あにめ'),
        ('samurai', 'samurai', 'さむらい'),
      ];
      for (final (desc, input, expected) in cases) {
        test(desc, () => expect(Kana.romajiToHiragana(input), expected));
      }
    });
  });
}
