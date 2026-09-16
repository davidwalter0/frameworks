/// Pure kana-conversion helpers. No Flutter dependency — trivially headless-
/// testable. All methods are side-effect-free (no I/O, no state).
///
/// Unicode ranges used throughout:
///   Hiragana : U+3041 – U+3096  (わ゛ etc. are outside; passed through)
///   Katakana  : U+30A1 – U+30F6  (block offset +0x60 from hiragana)
///   Half-width katakana (U+FF65 – U+FF9F) are never touched.
class Kana {
  Kana._();

  // -------------------------------------------------------------------------
  // Constants
  // -------------------------------------------------------------------------

  /// First codepoint of the hiragana block that has a katakana counterpart.
  static const int _hiraganaStart = 0x3041; // ぁ (small a)

  /// Last codepoint of the hiragana block that has a katakana counterpart.
  static const int _hiraganaEnd = 0x3096; // ゖ (small ke)

  /// First codepoint of the katakana block that maps back to hiragana.
  static const int _katakanaStart = 0x30A1; // ァ (small a)

  /// Last codepoint of the katakana block that maps back to hiragana.
  static const int _katakanaEnd = 0x30F6; // ヶ (small ke)

  /// Offset between the two blocks: katakana = hiragana + _offset.
  static const int _offset = 0x60;

  // -------------------------------------------------------------------------
  // Block-offset conversions
  // -------------------------------------------------------------------------

  /// Convert hiragana (U+3041–U+3096) to the corresponding katakana
  /// (U+30A1–U+30F6) using the fixed block offset (+0x60).
  ///
  /// All other code units — kanji, ASCII, the katakana long-vowel mark (ー),
  /// voiced-iteration marks (ゞ), half-width katakana, punctuation, etc. —
  /// are passed through unchanged.
  ///
  /// ```dart
  /// Kana.hiraganaToKatakana('きょう') // → 'キョウ'
  /// Kana.hiraganaToKatakana('abc')   // → 'abc'
  /// ```
  static String hiraganaToKatakana(final String s) {
    if (s.isEmpty) return s;
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final cu = s.codeUnitAt(i);
      if (cu >= _hiraganaStart && cu <= _hiraganaEnd) {
        buf.writeCharCode(cu + _offset);
      } else {
        buf.writeCharCode(cu);
      }
    }
    return buf.toString();
  }

  /// Convert katakana (U+30A1–U+30F6) to the corresponding hiragana
  /// (U+3041–U+3096) using the fixed block offset (−0x60).
  ///
  /// Katakana-only marks that have no hiragana counterpart — ・ (U+30FB),
  /// ー (U+30FC), ヽ (U+30FD), ヾ (U+30FE), ヿ (U+30FF), and half-width
  /// katakana (U+FF65–U+FF9F) — are passed through unchanged.
  ///
  /// ```dart
  /// Kana.katakanaToHiragana('キョウ') // → 'きょう'
  /// Kana.katakanaToHiragana('ー')    // → 'ー'  (passed through)
  /// ```
  static String katakanaToHiragana(final String s) {
    if (s.isEmpty) return s;
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final cu = s.codeUnitAt(i);
      if (cu >= _katakanaStart && cu <= _katakanaEnd) {
        buf.writeCharCode(cu - _offset);
      } else {
        buf.writeCharCode(cu);
      }
    }
    return buf.toString();
  }

  /// Toggle every kana character between hiragana and katakana in place: each
  /// hiragana (U+3041–U+3096) becomes its katakana counterpart and each katakana
  /// (U+30A1–U+30F6) its hiragana counterpart, via the fixed block offset
  /// (±0x60). All other code units — kanji, ASCII, the long-vowel mark (ー), and
  /// katakana-only marks with no hiragana counterpart — pass through unchanged.
  ///
  /// This is a per-character **involution**: applying it twice returns the
  /// original string, so it round-trips even for mixed text — the natural
  /// "toggle kana" transform for an editor command (a directional
  /// [hiraganaToKatakana] / [katakanaToHiragana] does not).
  ///
  /// ```dart
  /// Kana.toggleKana('きょう')  // → 'キョウ'
  /// Kana.toggleKana('キョウ')  // → 'きょう'
  /// Kana.toggleKana('あ漢ア')  // → 'ア漢あ'  (kanji unchanged, each kana flips)
  /// ```
  static String toggleKana(final String s) {
    if (s.isEmpty) return s;
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final cu = s.codeUnitAt(i);
      if (cu >= _hiraganaStart && cu <= _hiraganaEnd) {
        buf.writeCharCode(cu + _offset);
      } else if (cu >= _katakanaStart && cu <= _katakanaEnd) {
        buf.writeCharCode(cu - _offset);
      } else {
        buf.writeCharCode(cu);
      }
    }
    return buf.toString();
  }

  /// Whether [s] contains any hiragana (U+3041–U+3096) or katakana
  /// (U+30A1–U+30F6) code unit.
  static bool containsKana(final String s) {
    for (var i = 0; i < s.length; i++) {
      final cu = s.codeUnitAt(i);
      if ((cu >= _hiraganaStart && cu <= _hiraganaEnd) ||
          (cu >= _katakanaStart && cu <= _katakanaEnd)) {
        return true;
      }
    }
    return false;
  }

  /// Toggle between romaji and kana — the Emacs `toggle-input-method` (C-\)
  /// transform: `nihon` ⇄ `にほん`.
  ///
  /// If [s] [containsKana], convert it to Hepburn romaji ([toRomaji]); otherwise
  /// treat it as romaji and convert to hiragana ([romajiToHiragana]). It is NOT
  /// a strict involution — romaji↔kana has inherent ambiguity and the
  /// kana→romaji→kana round-trip lands on hiragana — but it is the natural
  /// two-way input toggle.
  ///
  /// ```dart
  /// Kana.toggleRomajiKana('nihon')  // → 'にほん'
  /// Kana.toggleRomajiKana('にほん')  // → 'nihon'
  /// Kana.toggleRomajiKana('ニホン')  // → 'nihon'
  /// ```
  static String toggleRomajiKana(final String s) =>
      containsKana(s) ? toRomaji(s) : romajiToHiragana(s);

  // -------------------------------------------------------------------------
  // Romaji → hiragana  (Hepburn, greedy longest-match)
  // -------------------------------------------------------------------------

  /// Hepburn romaji → hiragana table, longest sequences first so the greedy
  /// scan always picks the longest match. All keys are lower-case ASCII.
  ///
  /// Edge cases documented in-line:
  ///   * "n" before a consonant or at EOL → ん
  ///   * "nn"                             → ん  (disambiguator)
  ///   * "n'" (not covered — apostrophe passes through; treat "n" context)
  ///   * gemination: doubled consonant C+C → っ + C (e.g. "kk" → っk)
  ///   * youon (compound kana): "sha" → しゃ, "kya" → きゃ, etc.
  ///   * No macron support (ā/ō/ū): macrons pass through as-is.
  static const Map<String, String> _table = {
    // --- youon (3-char sequences first so they beat 2-char matches) ----------
    'sha': 'しゃ',
    'shi': 'し',
    'shu': 'しゅ',
    'she': 'しぇ',
    'sho': 'しょ',
    'chi': 'ち',
    'cha': 'ちゃ',
    'chu': 'ちゅ',
    'che': 'ちぇ',
    'cho': 'ちょ',
    'tsu': 'つ',
    'tchi': 'っち',
    'kya': 'きゃ',
    'kyi': 'きぃ',
    'kyu': 'きゅ',
    'kye': 'きぇ',
    'kyo': 'きょ',
    'gya': 'ぎゃ',
    'gyi': 'ぎぃ',
    'gyu': 'ぎゅ',
    'gye': 'ぎぇ',
    'gyo': 'ぎょ',
    'sya': 'しゃ',
    'syi': 'しぃ',
    'syu': 'しゅ',
    'sye': 'しぇ',
    'syo': 'しょ',
    'zya': 'じゃ',
    'zyi': 'じぃ',
    'zyu': 'じゅ',
    'zye': 'じぇ',
    'zyo': 'じょ',
    'tya': 'ちゃ',
    'tyi': 'ちぃ',
    'tyu': 'ちゅ',
    'tye': 'ちぇ',
    'tyo': 'ちょ',
    'dya': 'ぢゃ',
    'dyi': 'ぢぃ',
    'dyu': 'ぢゅ',
    'dye': 'ぢぇ',
    'dyo': 'ぢょ',
    'nya': 'にゃ',
    'nyi': 'にぃ',
    'nyu': 'にゅ',
    'nye': 'にぇ',
    'nyo': 'にょ',
    'hya': 'ひゃ',
    'hyi': 'ひぃ',
    'hyu': 'ひゅ',
    'hye': 'ひぇ',
    'hyo': 'ひょ',
    'bya': 'びゃ',
    'byi': 'びぃ',
    'byu': 'びゅ',
    'bye': 'びぇ',
    'byo': 'びょ',
    'pya': 'ぴゃ',
    'pyi': 'ぴぃ',
    'pyu': 'ぴゅ',
    'pye': 'ぴぇ',
    'pyo': 'ぴょ',
    'mya': 'みゃ',
    'myi': 'みぃ',
    'myu': 'みゅ',
    'mye': 'みぇ',
    'myo': 'みょ',
    'rya': 'りゃ',
    'ryi': 'りぃ',
    'ryu': 'りゅ',
    'rye': 'りぇ',
    'ryo': 'りょ',
    'jya': 'じゃ',
    'jyi': 'じぃ',
    'jyu': 'じゅ',
    'jye': 'じぇ',
    'jyo': 'じょ',
    'ja': 'じゃ',
    'ji': 'じ',
    'ju': 'じゅ',
    'je': 'じぇ',
    'jo': 'じょ',
    // --- 2-char sequences ----------------------------------------------------
    'ka': 'か',
    'ki': 'き',
    'ku': 'く',
    'ke': 'け',
    'ko': 'こ',
    'ga': 'が',
    'gi': 'ぎ',
    'gu': 'ぐ',
    'ge': 'げ',
    'go': 'ご',
    'sa': 'さ',
    'si': 'し',
    'su': 'す',
    'se': 'せ',
    'so': 'そ',
    'za': 'ざ',
    'zi': 'じ',
    'zu': 'ず',
    'ze': 'ぜ',
    'zo': 'ぞ',
    'ta': 'た',
    'ti': 'ち',
    'tu': 'つ',
    'te': 'て',
    'to': 'と',
    'da': 'だ',
    'di': 'ぢ',
    'du': 'づ',
    'de': 'で',
    'do': 'ど',
    'na': 'な',
    'ni': 'に',
    'nu': 'ぬ',
    'ne': 'ね',
    'no': 'の',
    'ha': 'は',
    'hi': 'ひ',
    'hu': 'ふ',
    'he': 'へ',
    'ho': 'ほ',
    'ba': 'ば',
    'bi': 'び',
    'bu': 'ぶ',
    'be': 'べ',
    'bo': 'ぼ',
    'pa': 'ぱ',
    'pi': 'ぴ',
    'pu': 'ぷ',
    'pe': 'ぺ',
    'po': 'ぽ',
    'ma': 'ま',
    'mi': 'み',
    'mu': 'む',
    'me': 'め',
    'mo': 'も',
    'ya': 'や',
    'yu': 'ゆ',
    'yo': 'よ',
    'ra': 'ら',
    'ri': 'り',
    'ru': 'る',
    're': 'れ',
    'ro': 'ろ',
    'wa': 'わ',
    'wi': 'ゐ',
    'we': 'ゑ',
    'wo': 'を',
    'fu': 'ふ',
    'fa': 'ふぁ',
    'fi': 'ふぃ',
    'fe': 'ふぇ',
    'fo': 'ふぉ',
    'nn': 'ん', // explicit double-n before a vowel
    // --- 1-char vowels -------------------------------------------------------
    'a': 'あ',
    'i': 'い',
    'u': 'う',
    'e': 'え',
    'o': 'お',
    // --- lone n (resolved in the algorithm, not via a simple table hit) ------
    // 'n' → handled in code after the table scan.
  };

  /// The set of romaji vowel characters, used by the [romajiToHiragana]
  /// algorithm to decide whether a standalone "n" should become ん.
  static const Set<String> _vowels = {'a', 'e', 'i', 'o', 'u'};

  /// The set of ASCII consonant characters that can start a geminated pair
  /// (e.g. the first 'k' in "kka"). This excludes 'n' (handled separately).
  static const Set<String> _consonants = {
    'b',
    'c',
    'd',
    'f',
    'g',
    'h',
    'j',
    'k',
    'l',
    'm',
    'p',
    'q',
    'r',
    's',
    't',
    'v',
    'w',
    'x',
    'y',
    'z',
  };

  /// Maximum key length in [_table], so the greedy scan window is bounded.
  static const int _maxKeyLen = 4;

  // -------------------------------------------------------------------------
  // Incremental-input support (used by RomajiInputBuffer)
  // -------------------------------------------------------------------------

  /// Set of every *strict prefix* of a [_table] key (excluding the keys'
  /// final characters), e.g. `k`, `ky`, `sh`, `ch`, `ts`, `tc`, `tch`, `n`,
  /// `ny`, … Computed once from [_table] so the table stays the single source
  /// of truth.
  ///
  /// A romaji fragment that is in this set could still grow into a longer (and
  /// possibly different) kana — so an incremental converter must keep it
  /// *pending* rather than committing it.  This is exactly the predicate
  /// [isRomajiPrefix] exposes.
  static final Set<String> _strictPrefixes = _computeStrictPrefixes();

  static Set<String> _computeStrictPrefixes() {
    final out = <String>{};
    for (final key in _table.keys) {
      // Every prefix shorter than the key itself is a "live" prefix.
      for (var len = 1; len < key.length; len++) {
        out.add(key.substring(0, len));
      }
    }
    return out;
  }

  /// True when [s] is a *strict prefix* of at least one recognised romaji
  /// unit — i.e. typing more characters could extend it into a longer mora
  /// (`k` → `ka`/`kya`, `sh` → `sha`/`shi`, `ts` → `tsu`, `n` → `na`/`nya`,
  /// `tc` → `tchi`, …).
  ///
  /// Used by the incremental romaji input buffer to decide whether the
  /// currently-buffered fragment is still "open" (keep pending) or has become
  /// un-extendable (resolve and emit). Pure; no side effects.
  ///
  /// ```dart
  /// Kana.isRomajiPrefix('k')   // true  (→ ka, ki, kya, …)
  /// Kana.isRomajiPrefix('ky')  // true  (→ kya, kyo, …)
  /// Kana.isRomajiPrefix('ka')  // false (no longer romaji unit starts "ka")
  /// Kana.isRomajiPrefix('a')   // false (a vowel is terminal)
  /// ```
  static bool isRomajiPrefix(final String s) {
    if (s.isEmpty) return false;
    return _strictPrefixes.contains(s.toLowerCase());
  }

  /// The longest [_table] key (length 1..[_maxKeyLen]) that is a prefix of
  /// [s], or `null` if none matches. Used by the incremental converter to
  /// peel one completed mora off the front of the pending buffer.
  ///
  /// Returns a record of (key, kana). Pure; no side effects.
  static (String key, String kana)? longestRomajiUnitAt(final String s) {
    final lower = s.toLowerCase();
    final maxLen = _maxKeyLen < lower.length ? _maxKeyLen : lower.length;
    for (var len = maxLen; len >= 1; len--) {
      final key = lower.substring(0, len);
      final kana = _table[key];
      if (kana != null) return (key, kana);
    }
    return null;
  }

  /// True if [ch] is a single ASCII consonant that can begin a geminated pair
  /// (the doubled-consonant `っ` rule). Excludes `n` (handled separately).
  static bool isGeminationConsonant(final String ch) =>
      ch.length == 1 && _consonants.contains(ch);

  /// True if [ch] is a single romaji vowel (`a`/`e`/`i`/`o`/`u`).
  static bool isVowel(final String ch) => _vowels.contains(ch);

  // -------------------------------------------------------------------------
  // Hiragana / katakana → Hepburn romaji
  // -------------------------------------------------------------------------

  /// Hiragana → Hepburn romaji table.
  ///
  /// Keys are hiragana strings (one or two code points), values are romaji.
  /// Longer keys (youon — base + small y-kana) appear first so the greedy
  /// scan always prefers the longer match.
  ///
  /// Edge-cases handled by the algorithm, not the table:
  ///   * small-っ → geminate the next romaji consonant (e.g. がっこう→gakkou).
  ///     Trailing っ emits "t".
  ///   * ん before a vowel or 'y' → "n'" (e.g. しんよう→shin'you).
  ///     Elsewhere ん → "n".
  ///   * katakana long-vowel mark ー and any unmapped character pass through.
  static const Map<String, String> _toRomajiTable = {
    // --- youon (two-kana sequences, listed first) ----------------------------
    'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
    'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
    'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho',
    'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo',
    'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho',
    'ぢゃ': 'dya', 'ぢゅ': 'dyu', 'ぢょ': 'dyo',
    'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
    'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
    'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
    'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
    'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
    'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
    // --- single kana ---------------------------------------------------------
    'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
    'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
    'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
    'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
    'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
    'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
    'だ': 'da', 'ぢ': 'di', 'づ': 'zu', 'で': 'de', 'ど': 'do',
    'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
    'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
    'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
    'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
    'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
    'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
    'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
    'わ': 'wa', 'ゐ': 'wi', 'ゑ': 'we', 'を': 'o',
    'ん': 'n',
    // small kana (standalone — appear after base-kana)
    'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o',
    'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo',
    'っ': 't', // trailing small-tsu fallback
  };

  static const Set<String> _romajiVowelStarts = {'a', 'e', 'i', 'o', 'u'};

  /// Convert hiragana AND katakana to Hepburn romaji.
  ///
  /// Normalises katakana→hiragana first (reusing [katakanaToHiragana]), then
  /// maps via [_toRomajiTable].  Non-kana characters (kanji, ASCII, digits,
  /// punctuation, the katakana long-vowel mark ー) are emitted verbatim.
  ///
  /// Special rules:
  ///   * **Gemination (っ)**: small-tsu before a convertible kana → doubles the
  ///     first romaji consonant of the next mora (がっこう→gakkou, きって→kitte).
  ///     Trailing っ or っ before an unmapped character → "t".
  ///   * **ん disambiguator**: ん before a romaji vowel-start or 'y' emits "n'"
  ///     (e.g. しんよう→shin'you, さんあん→san'an).  Elsewhere ん → "n".
  ///
  /// ```dart
  /// Kana.toRomaji('あいうえお')   // → 'aiueo'
  /// Kana.toRomaji('きゃ')         // → 'kya'
  /// Kana.toRomaji('がっこう')     // → 'gakkou'
  /// Kana.toRomaji('しんぶん')     // → 'shinbun'
  /// Kana.toRomaji('ニホンゴ')     // → 'nihongo'
  /// Kana.toRomaji('hello')        // → 'hello'   (pass-through)
  /// ```
  static String toRomaji(final String s) {
    if (s.isEmpty) return s;
    // Normalise katakana → hiragana first; non-katakana characters are unchanged.
    final hira = katakanaToHiragana(s);
    final buf = StringBuffer();
    var i = 0;

    // We work on the Dart string (UTF-16 code units). Each hiragana character
    // is a single code unit (U+3041–U+3096), so index arithmetic is safe here.
    while (i < hira.length) {
      // Try a two-kana youon match first (base kana + small ゃゅょ).
      if (i + 1 < hira.length) {
        final twoChar = hira.substring(i, i + 2);
        final hit2 = _toRomajiTable[twoChar];
        if (hit2 != null) {
          buf.write(hit2);
          i += 2;
          continue;
        }
      }

      final ch = hira[i];

      // Small-tsu (っ) → gemination: double the leading consonant of the next mora.
      if (ch == 'っ') {
        // Peek at what the next mora maps to.
        String? nextRomaji;
        if (i + 2 < hira.length) {
          nextRomaji = _toRomajiTable[hira.substring(i + 1, i + 3)];
        }
        nextRomaji ??= _toRomajiTable[i + 1 < hira.length ? hira[i + 1] : ''];
        if (nextRomaji != null && nextRomaji.isNotEmpty) {
          buf.write(nextRomaji[0]); // duplicate leading consonant
        } else {
          buf.write('t'); // trailing or unrecognised → fallback
        }
        i++;
        continue;
      }

      // ん → "n" with optional disambiguating apostrophe.
      if (ch == 'ん') {
        // Check what the *next* mora starts with in romaji.
        String? nextMoraRomaji;
        if (i + 2 < hira.length) {
          nextMoraRomaji = _toRomajiTable[hira.substring(i + 1, i + 3)];
        }
        nextMoraRomaji ??=
            _toRomajiTable[i + 1 < hira.length ? hira[i + 1] : ''];
        final first = nextMoraRomaji != null && nextMoraRomaji.isNotEmpty
            ? nextMoraRomaji[0]
            : '';
        final needApostrophe =
            _romajiVowelStarts.contains(first) || first == 'y';
        buf.write(needApostrophe ? "n'" : 'n');
        i++;
        continue;
      }

      // Single-kana table hit.
      final hit1 = _toRomajiTable[ch];
      if (hit1 != null) {
        buf.write(hit1);
        i++;
        continue;
      }

      // Pass-through: kanji, ASCII, ー, punctuation, etc.
      buf.write(ch);
      i++;
    }
    return buf.toString();
  }

  /// Convert Hepburn romaji to hiragana using a greedy longest-match scan
  /// over [_table].
  ///
  /// Rules applied in order at each position:
  ///
  /// 1. **Gemination** — if the current character is a consonant (not 'n')
  ///    and the *next* character is identical, emit っ and advance by one
  ///    (leaving the second consonant to start the next match).
  ///    e.g. `kk` → っ then `ka` → か, yielding っか.
  ///
  /// 2. **Standalone "n"** — emit ん when the 'n' cannot start a kana syllable:
  ///    - end of input: `n` → ん.
  ///    - 'n' before a consonant that is neither 'n' nor 'y': e.g. `nk` →
  ///      んk. 'y' is excluded here because `ny*` (nya/nyu/nyo) are table
  ///      keys, so 'n' before 'y' must fall through to a youon match.
  ///    - 'n' before 'n' that is itself followed by a vowel: `anna` =
  ///      `a` + ん + `na` → あんな. This three-character lookahead prevents
  ///      the `nn` table entry from consuming both n-chars when the second 'n'
  ///      is the start of a `na/ni/…` syllable.
  ///    'n' followed directly by a vowel (or 'y') falls through to the table
  ///    (`na`, `nya`, etc.) so that it becomes a proper n-row/youon kana.
  ///
  /// 3. **Longest-match table lookup** — try keys of length [_maxKeyLen] down
  ///    to 1; use the first match found.
  ///
  /// 4. **Pass-through** — unrecognised characters (ASCII punctuation, digits,
  ///    kanji, already-converted kana, whitespace) are emitted verbatim.
  ///
  /// Long vowels are written as double vowels ('aa', 'oo', 'uu', etc.) and
  /// each resolves to two hiragana (e.g. 'oo' → おお). Macron characters
  /// (ā, ū, ō) are passed through unchanged.
  ///
  /// ```dart
  /// Kana.romajiToHiragana('konnichiwa') // → 'こんにちわ'
  /// Kana.romajiToHiragana('gakkou')     // → 'がっこう'
  /// Kana.romajiToHiragana('kyou')       // → 'きょう'
  /// Kana.romajiToHiragana('anna')       // → 'あんな'  (n+n+vowel lookahead)
  /// Kana.romajiToHiragana('XYZ 123')    // → 'XYZ 123'    (pass-through)
  /// ```
  static String romajiToHiragana(final String s) {
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    final buf = StringBuffer();
    var i = 0;
    while (i < lower.length) {
      final ch = lower[i];

      // 1. Gemination: consonant followed by the same consonant.
      if (_consonants.contains(ch) &&
          i + 1 < lower.length &&
          lower[i + 1] == ch) {
        // Special-case: 'tch' is already in the table as 'tchi'; skip
        // gemination for 't' if the following pair is 'ch'.
        final isTch = ch == 't' &&
            i + 2 < lower.length &&
            lower[i + 1] == 'c' &&
            lower[i + 2] == 'h';
        if (!isTch) {
          buf.write('っ');
          i++; // advance past the first copy; let loop pick up the second
          continue;
        }
      }

      // 2. Standalone "n": emit ん when 'n' cannot start a kana syllable.
      if (ch == 'n') {
        final next = (i + 1 < lower.length) ? lower[i + 1] : '';
        final next2 = (i + 2 < lower.length) ? lower[i + 2] : '';

        // Fire the standalone-ん rule when:
        //   (a) end of input — trailing bare 'n',
        //   (b) next is a consonant other than 'n' or 'y' — 'nk', 'nb', …
        //       'y' is excluded because 'ny*' keys (nya/nyu/nyo) are in the
        //       table, so 'n' before 'y' must fall through to a table hit.
        //   (c) next is 'n' AND the char after that is a vowel — the 'anna'
        //       pattern: emit ん here so the loop can consume 'na'/'ni'/…
        //       as a proper n-row kana. Without this three-char lookahead the
        //       greedy 'nn' table key would fire and turn 'anna' into あんあ.
        final standalone = next.isEmpty ||
            (!_vowels.contains(next) && next != 'n' && next != 'y') ||
            (next == 'n' && _vowels.contains(next2));
        if (standalone) {
          buf.write('ん');
          i++;
          continue;
        }
        // Otherwise fall through to the table scan ('na', 'ni', 'nn', etc.).
      }

      // 3. Greedy longest-match table lookup.
      var matched = false;
      final maxLen =
          _maxKeyLen < lower.length - i ? _maxKeyLen : lower.length - i;
      for (var len = maxLen; len >= 1; len--) {
        final key = lower.substring(i, i + len);
        final kana = _table[key];
        if (kana != null) {
          buf.write(kana);
          i += len;
          matched = true;
          break;
        }
      }

      // 4. Pass-through for unrecognised characters.
      if (!matched) {
        buf.write(s[i]); // preserve original case for pass-through
        i++;
      }
    }
    return buf.toString();
  }
}
