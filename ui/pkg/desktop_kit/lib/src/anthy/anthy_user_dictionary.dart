// Anthy's personal dictionary — the words the SYSTEM dictionary does not have.
//
// Anthy ships a fixed system dictionary and reads a per-user dictionary beside
// it. Words absent from both simply have no kanji candidate: おめでとう, for
// instance, offers only ['おめでとう', 'オメデトウ'] out of the box — 御目出度う
// is not in anthy's dictionary at all, however ordinary the word is. That is not
// a conversion bug and no amount of driving the egg protocol will surface it;
// the word has to be registered.
//
// This is the pure half — parse, render, add, remove — with no `dart:io`, so it
// compiles for web and is testable without touching a real dictionary. The file
// I/O lives in `anthy_user_dictionary_io.dart`.
//
// ## The file
//
// One line per word, in anthy's compact form:
//
// ```
// おめでとう #T37*1 御目出度う
// ⟨reading⟩ #⟨type⟩*⟨frequency⟩ ⟨word⟩
// ```
//
// Empirically pinned against anthy 0.4 (`anthy-agent --egg`, 2026-07-26):
//
//   * The file IS the source of truth — there is no compiled sidecar. A word
//     written straight into it is offered by the next agent that starts. A
//     RUNNING agent does not see the change: it reads the dictionary once at
//     startup, so a caller must restart its agent (see [AnthyUserDictionary]'s
//     `save` in the I/O half, which says so at the call site).
//   * `anthy-dic-tool --load` writes exactly this format, so the two are
//     interchangeable and no subprocess is required to register a word.
//   * **The file must already exist**, or `anthy-dic-tool` fails with
//     `Failed to register ⟨reading⟩` and creates nothing — it only ever opens
//     the path `O_RDONLY`. This is the single most obnoxious part of the
//     mechanism and the reason registration "silently" does nothing on a fresh
//     account; the I/O half creates the file (and `~/.anthy`) up front.
//   * A user word does NOT always win. `おまたせ → 御待たせ` stays invisible
//     even at frequency 1000, because the system dictionary already answers
//     that reading with お待たせ. Registration adds candidates for readings the
//     system dictionary is thin on; it is not an override mechanism.
library;

import 'package:flutter/foundation.dart' show immutable;

/// A part-of-speech code from anthy's `/usr/share/anthy/typetab`.
///
/// Only the handful worth naming are here — the code is a plain string, so any
/// type in `typetab` can be used by passing it directly. The distinctions that
/// matter for a registered word are whether it can stand as its own bunsetsu
/// and what may attach to it.
abstract final class AnthyWordType {
  /// Noun, stands alone as a bunsetsu, takes case particles (を, が, に …).
  /// The right default for an ordinary noun.
  static const String noun = 'T35';

  /// Noun, stands alone as a bunsetsu, takes NO case particles. The right
  /// choice for a set phrase or greeting used on its own — おめでとう,
  /// お待たせ — which is why it is [AnthyUserWord]'s default.
  static const String setPhrase = 'T37';

  /// Noun that also takes する (勉強 → 勉強する).
  static const String suruNoun = 'T30';

  /// Personal name.
  static const String personalName = 'JNM';

  /// Place name.
  static const String placeName = 'CN';

  /// Adjective (形容詞).
  static const String adjective = 'KY';
}

/// One personal-dictionary word: a hiragana [reading] converting to [word].
@immutable
class AnthyUserWord {
  /// Create a word. [type] defaults to [AnthyWordType.setPhrase] and
  /// [frequency] to 1 — see the field docs for why those are the safe defaults.
  const AnthyUserWord({
    required this.reading,
    required this.word,
    this.type = AnthyWordType.setPhrase,
    this.frequency = 1,
  });

  /// The hiragana reading typed to reach [word].
  final String reading;

  /// The text offered as a candidate for [reading].
  final String word;

  /// Part-of-speech code from `typetab` (see [AnthyWordType]). Defaults to
  /// [AnthyWordType.setPhrase]: a registered word is far more often a phrase
  /// the system dictionary lacks than a noun taking case particles, and the
  /// wrong choice mis-segments the phrases around it.
  final String type;

  /// Relative weight against other candidates for the same reading. Higher
  /// sorts earlier, but does NOT override a system-dictionary answer — see the
  /// library docs. 1 is the value `anthy-dic-tool` itself writes.
  final int frequency;

  /// This word as its dictionary line, without a trailing newline.
  String get line => '$reading #$type*$frequency $word';

  /// Parse one dictionary line, or null when [line] is blank, a `#` comment, or
  /// malformed.
  ///
  /// Returning null rather than throwing is deliberate: this file is
  /// hand-editable and may be edited by `anthy-dic-tool` or another IME
  /// front-end, so one unreadable line must not cost the user the rest of their
  /// dictionary.
  static AnthyUserWord? parseLine(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
    final List<String> parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 3) return null;
    final String reading = parts[0];
    final Match? spec =
        RegExp(r'^#([A-Za-z0-9]+)\*(\d+)$').firstMatch(parts[1]);
    if (spec == null) return null;
    // The word is the remainder, so a word containing whitespace survives.
    final String word = parts.sublist(2).join(' ');
    if (reading.isEmpty || word.isEmpty) return null;
    return AnthyUserWord(
      reading: reading,
      word: word,
      type: spec.group(1)!,
      frequency: int.parse(spec.group(2)!),
    );
  }

  /// Two words are the same ENTRY when the reading and the word match; the type
  /// and frequency are properties OF that entry, not part of its identity. So
  /// re-adding おめでとう→御目出度う at a different frequency updates it rather
  /// than duplicating it (see [AnthyUserDictionary.withWord]).
  bool sameEntry(AnthyUserWord other) =>
      reading == other.reading && word == other.word;

  @override
  bool operator ==(Object other) =>
      other is AnthyUserWord &&
      other.reading == reading &&
      other.word == word &&
      other.type == type &&
      other.frequency == frequency;

  @override
  int get hashCode => Object.hash(reading, word, type, frequency);

  @override
  String toString() => 'AnthyUserWord($line)';
}

/// An immutable view of anthy's personal dictionary: a list of
/// [AnthyUserWord]s that parses from and renders to the on-disk format.
///
/// Mutation returns a new dictionary ([withWord] / [withoutWord]) so a caller
/// can diff, confirm, or discard before writing anything to disk.
@immutable
class AnthyUserDictionary {
  /// Create a dictionary over [words] (defensively copied).
  AnthyUserDictionary(Iterable<AnthyUserWord> words)
      : words = List<AnthyUserWord>.unmodifiable(words);

  /// An empty dictionary — what a fresh account has.
  static final AnthyUserDictionary empty =
      AnthyUserDictionary(const <AnthyUserWord>[]);

  /// The words, in file order.
  final List<AnthyUserWord> words;

  /// The dictionary filename anthy reads for the default personality.
  ///
  /// Anthy resolves the home directory through `getpwuid`, NOT `$HOME` — an
  /// overridden `HOME` is ignored, so a caller cannot redirect a real agent at
  /// a scratch dictionary by setting the environment variable. Tests must use
  /// the pure layer here rather than trying to sandbox a live agent.
  static const String fileName = 'private_words_default';

  /// Directory (relative to the user's home) holding anthy's per-user state.
  static const String directoryName = '.anthy';

  /// Parse a whole dictionary file. Unreadable lines are skipped, not fatal.
  factory AnthyUserDictionary.parse(String contents) => AnthyUserDictionary(
        contents
            .split('\n')
            .map(AnthyUserWord.parseLine)
            .whereType<AnthyUserWord>(),
      );

  /// Render to the on-disk format, newline-terminated (empty when there are no
  /// words — anthy accepts an empty file, and it must EXIST for registration to
  /// work at all).
  String render() => words.isEmpty
      ? ''
      : '${words.map((AnthyUserWord w) => w.line).join('\n')}\n';

  /// Whether any entry has this exact reading and word.
  bool contains(AnthyUserWord word) =>
      words.any((AnthyUserWord w) => w.sameEntry(word));

  /// Every word registered for [reading].
  List<AnthyUserWord> forReading(String reading) => words
      .where((AnthyUserWord w) => w.reading == reading)
      .toList(growable: false);

  /// This dictionary plus [word] — REPLACING any entry with the same reading
  /// and word (so re-registering updates the type/frequency in place, keeping
  /// its position) and appending otherwise.
  AnthyUserDictionary withWord(AnthyUserWord word) {
    final int at = words.indexWhere((AnthyUserWord w) => w.sameEntry(word));
    if (at < 0) {
      return AnthyUserDictionary(<AnthyUserWord>[...words, word]);
    }
    final List<AnthyUserWord> next = List<AnthyUserWord>.of(words);
    next[at] = word;
    return AnthyUserDictionary(next);
  }

  /// This dictionary without any entry matching [word]'s reading and word.
  AnthyUserDictionary withoutWord(AnthyUserWord word) => AnthyUserDictionary(
        words.where((AnthyUserWord w) => !w.sameEntry(word)),
      );

  /// This dictionary without any entry for [reading].
  AnthyUserDictionary withoutReading(String reading) => AnthyUserDictionary(
        words.where((AnthyUserWord w) => w.reading != reading),
      );

  @override
  String toString() => 'AnthyUserDictionary(${words.length} words)';
}
