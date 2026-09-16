// Anthy personal dictionary — parse/render and the file operations.
//
// The on-disk format and every behavioural claim below were pinned against a
// real anthy 0.4 (`anthy-agent --egg` + `anthy-dic-tool`, 2026-07-26), not read
// out of documentation:
//
//   * `anthy-dic-tool --load` writes `おめでとう #T37*1 御目出度う`;
//   * a word written straight into the file (no dic-tool) is offered by the
//     next agent — GET-CANDIDATES for おめでとう went from
//     ['おめでとう','オメデトウ'] to ['おめでとう','御目出度う','オメデトウ'];
//   * the file must EXIST first — dic-tool opens it O_RDONLY and fails with
//     "Failed to register" while creating nothing. That is the case
//     `ensureExists` / `save` are for, and the one a test can most easily miss,
//     so it is asserted directly.
import 'dart:io';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:desktop_kit/desktop_kit_anthy_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnthyUserWord — the on-disk line', () {
    test('renders exactly the form anthy-dic-tool writes', () {
      const AnthyUserWord w = AnthyUserWord(
        reading: 'おめでとう',
        word: '御目出度う',
        type: AnthyWordType.setPhrase,
        frequency: 1,
      );
      expect(w.line, 'おめでとう #T37*1 御目出度う');
    });

    test('parses that line back, round-tripping every field', () {
      final AnthyUserWord? w = AnthyUserWord.parseLine('おめでとう #T37*1 御目出度う');
      expect(w, isNotNull);
      expect(w!.reading, 'おめでとう');
      expect(w.word, '御目出度う');
      expect(w.type, 'T37');
      expect(w.frequency, 1);
      expect(w.line, 'おめでとう #T37*1 御目出度う');
    });

    test('parses a multi-digit frequency and a non-T type', () {
      final AnthyUserWord? w = AnthyUserWord.parseLine('くろだじろう #JNM*500 玄田次郎');
      expect(w!.type, 'JNM');
      expect(w.frequency, 500);
      expect(w.word, '玄田次郎');
    });

    test('skips blanks, comments and malformed lines instead of throwing', () {
      // A hand-editable file shared with anthy-dic-tool and other front-ends:
      // one bad line must not cost the user the rest of the dictionary.
      expect(AnthyUserWord.parseLine(''), isNull);
      expect(AnthyUserWord.parseLine('   '), isNull);
      expect(AnthyUserWord.parseLine('# a comment'), isNull);
      expect(AnthyUserWord.parseLine('おめでとう 御目出度う'), isNull,
          reason: 'no type/frequency field');
      expect(AnthyUserWord.parseLine('おめでとう T37*1 御目出度う'), isNull,
          reason: 'type field must be #-prefixed');
      expect(AnthyUserWord.parseLine('おめでとう #T37 御目出度う'), isNull,
          reason: 'frequency is not optional in the on-disk form');
    });

    test('identity is (reading, word) — not type or frequency', () {
      const AnthyUserWord a = AnthyUserWord(
        reading: 'おめでとう',
        word: '御目出度う',
      );
      const AnthyUserWord b = AnthyUserWord(
        reading: 'おめでとう',
        word: '御目出度う',
        type: AnthyWordType.noun,
        frequency: 900,
      );
      expect(a.sameEntry(b), isTrue);
      expect(a == b, isFalse, reason: 'equality still compares every field');
    });
  });

  group('AnthyUserDictionary', () {
    test('parses a whole file, skipping noise, and renders it back', () {
      final AnthyUserDictionary d = AnthyUserDictionary.parse(
        '# Anthy personal dictionary\n'
        'おめでとう #T37*1 御目出度う\n'
        '\n'
        'garbage line\n'
        'くろだじろう #JNM*500 玄田次郎\n',
      );
      expect(d.words, hasLength(2));
      expect(
        d.render(),
        'おめでとう #T37*1 御目出度う\nくろだじろう #JNM*500 玄田次郎\n',
      );
    });

    test('an empty dictionary renders empty — the file still has to exist', () {
      expect(AnthyUserDictionary.empty.render(), '');
    });

    test('withWord appends a new entry', () {
      final AnthyUserDictionary d = AnthyUserDictionary.empty.withWord(
        const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'),
      );
      expect(d.words, hasLength(1));
      expect(d.render(), 'おめでとう #T37*1 御目出度う\n');
    });

    test('withWord UPDATES in place rather than duplicating a reading+word',
        () {
      final AnthyUserDictionary d = AnthyUserDictionary.parse(
        'おめでとう #T37*1 御目出度う\nくろだじろう #JNM*500 玄田次郎\n',
      ).withWord(const AnthyUserWord(
        reading: 'おめでとう',
        word: '御目出度う',
        frequency: 900,
      ));

      expect(d.words, hasLength(2),
          reason: 're-registering must not duplicate');
      expect(d.words.first.frequency, 900);
      expect(d.words.first.reading, 'おめでとう',
          reason: 'the updated entry keeps its position in the file');
    });

    test('two different words for the SAME reading both survive', () {
      // Multiple candidates per reading is the normal case, not a conflict.
      final AnthyUserDictionary d = AnthyUserDictionary.empty
          .withWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'))
          .withWord(const AnthyUserWord(reading: 'おめでとう', word: 'お目出度う'));
      expect(d.words, hasLength(2));
      expect(d.forReading('おめでとう'), hasLength(2));
    });

    test('withoutWord removes one entry; withoutReading removes them all', () {
      final AnthyUserDictionary d = AnthyUserDictionary.empty
          .withWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'))
          .withWord(const AnthyUserWord(reading: 'おめでとう', word: 'お目出度う'))
          .withWord(const AnthyUserWord(reading: 'くろだじろう', word: '玄田次郎'));

      expect(
        d
            .withoutWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'))
            .words,
        hasLength(2),
      );
      expect(d.withoutReading('おめでとう').words, hasLength(1));
      expect(d.withoutReading('おめでとう').words.single.word, '玄田次郎');
    });

    test('removal ignores type and frequency, matching identity', () {
      final AnthyUserDictionary d = AnthyUserDictionary.parse(
        'おめでとう #T37*1 御目出度う\n',
      ).withoutWord(const AnthyUserWord(
        reading: 'おめでとう',
        word: '御目出度う',
        type: AnthyWordType.noun,
        frequency: 999,
      ));
      expect(d.words, isEmpty);
    });

    test('contains matches on identity, not on the full record', () {
      final AnthyUserDictionary d =
          AnthyUserDictionary.parse('おめでとう #T37*1 御目出度う\n');
      expect(
        d.contains(const AnthyUserWord(
            reading: 'おめでとう', word: '御目出度う', frequency: 42)),
        isTrue,
      );
      expect(
        d.contains(const AnthyUserWord(reading: 'おめでとう', word: 'お芽出度う')),
        isFalse,
      );
    });
  });

  group('AnthyUserDictionaryFile', () {
    late Directory tmp;
    late AnthyUserDictionaryFile file;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('anthy_dict_test');
      file = AnthyUserDictionaryFile(
          '${tmp.path}/.anthy/${AnthyUserDictionary.fileName}');
    });

    tearDown(() async => tmp.delete(recursive: true));

    test('load on a fresh account is empty, not an error', () async {
      final AnthyUserDictionary d = await file.load();
      expect(d.words, isEmpty);
    });

    test('ensureExists CREATES the file — the whole point of the class',
        () async {
      // anthy-dic-tool opens this path O_RDONLY and fails with
      // "Failed to register" when it is missing, creating nothing. Registration
      // through any front-end is dead until the file exists.
      expect(File(file.path).existsSync(), isFalse);

      expect(await file.ensureExists(), isTrue, reason: 'it created the file');
      expect(File(file.path).existsSync(), isTrue);
      expect(File(file.path).readAsStringSync(), '');

      expect(await file.ensureExists(), isFalse,
          reason: 'second call is a no-op and says so');
    });

    test('ensureExists creates the ~/.anthy directory too', () async {
      expect(Directory('${tmp.path}/.anthy').existsSync(), isFalse);
      await file.ensureExists();
      expect(Directory('${tmp.path}/.anthy').existsSync(), isTrue);
    });

    test('ensureExists does not clobber an existing dictionary', () async {
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      expect(await file.ensureExists(), isFalse);
      expect((await file.load()).words, hasLength(1),
          reason: 'the existing word survives');
    });

    test('addWord writes the exact on-disk format, creating the tree',
        () async {
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      expect(
        File(file.path).readAsStringSync(),
        'おめでとう #T37*1 御目出度う\n',
        reason: 'byte-for-byte what anthy-dic-tool --load produces',
      );
    });

    test('addWord round-trips through the file, accumulating words', () async {
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      final AnthyUserDictionary d = await file
          .addWord(const AnthyUserWord(reading: 'くろだじろう', word: '玄田次郎'));

      expect(d.words, hasLength(2));
      expect((await file.load()).words, hasLength(2),
          reason: 'read back from disk, not just the returned value');
    });

    test('re-adding a word updates it on disk instead of duplicating',
        () async {
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      await file.addWord(
          const AnthyUserWord(reading: 'おめでとう', word: '御目出度う', frequency: 900));

      expect(File(file.path).readAsStringSync(), 'おめでとう #T37*900 御目出度う\n');
    });

    test('removeWord rewrites the file without it', () async {
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      await file.addWord(const AnthyUserWord(reading: 'くろだじろう', word: '玄田次郎'));

      await file
          .removeWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));

      expect(File(file.path).readAsStringSync(), 'くろだじろう #T37*1 玄田次郎\n');
    });

    test('emptying the dictionary leaves the FILE in place', () async {
      // Deleting the file would break the next registration through
      // anthy-dic-tool, so an empty dictionary is an empty file.
      await file.addWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));
      await file
          .removeWord(const AnthyUserWord(reading: 'おめでとう', word: '御目出度う'));

      expect(File(file.path).existsSync(), isTrue);
      expect(File(file.path).readAsStringSync(), '');
    });

    test('forCurrentUser builds the path anthy actually reads', () {
      final AnthyUserDictionaryFile f = AnthyUserDictionaryFile.forCurrentUser(
        environment: <String, String>{'HOME': '/home/someone'},
      );
      expect(f.path, '/home/someone/.anthy/private_words_default');
    });
  });
}
