/// File I/O for anthy's personal dictionary — `dart:io` only.
///
/// Split from `anthy_user_dictionary.dart` so the parse/render half stays
/// web-compilable, matching how the egg transport is split from its driver.
library;

import 'dart:io';

import 'anthy_user_dictionary.dart';

/// Reads and writes `~/.anthy/private_words_default`.
///
/// The one thing this class exists to get right: **anthy will not create the
/// dictionary file.** `anthy-dic-tool` opens the path `O_RDONLY` and, when it
/// is missing, fails with `Failed to register ⟨reading⟩` while creating
/// nothing — so registration appears to succeed-then-do-nothing on any account
/// that has never registered a word. [save] and [ensureExists] create the
/// directory and the file up front.
class AnthyUserDictionaryFile {
  /// Point at an explicit dictionary [path]. Prefer [forCurrentUser] in
  /// production; this constructor is what makes the class testable against a
  /// temp directory.
  const AnthyUserDictionaryFile(this.path);

  /// The dictionary anthy reads for the current user.
  ///
  /// Resolved from `$HOME` (falling back to `$USERPROFILE`) because that is all
  /// Dart exposes — but note anthy itself resolves the home directory through
  /// `getpwuid` and IGNORES `$HOME`. The two agree for a normal desktop
  /// session; where they disagree, anthy wins, so overriding `HOME` cannot
  /// redirect a live agent at a scratch dictionary. Pass an explicit path to
  /// the default constructor instead.
  factory AnthyUserDictionaryFile.forCurrentUser({
    Map<String, String>? environment,
  }) {
    final Map<String, String> env = environment ?? Platform.environment;
    final String home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    return AnthyUserDictionaryFile(
      '$home${Platform.pathSeparator}${AnthyUserDictionary.directoryName}'
      '${Platform.pathSeparator}${AnthyUserDictionary.fileName}',
    );
  }

  /// Absolute path to the dictionary file.
  final String path;

  /// Read the dictionary, or [AnthyUserDictionary.empty] when the file does not
  /// exist yet (a fresh account — not an error).
  Future<AnthyUserDictionary> load() async {
    final File file = File(path);
    if (!await file.exists()) return AnthyUserDictionary.empty;
    return AnthyUserDictionary.parse(await file.readAsString());
  }

  /// Create the directory and an EMPTY dictionary file if either is missing,
  /// and report whether anything was created.
  ///
  /// Worth calling on its own at startup: it is the difference between
  /// `anthy-dic-tool` working and failing, so a host that wants users to be
  /// able to register words through any front-end can fix that once, up front.
  Future<bool> ensureExists() async {
    final File file = File(path);
    if (await file.exists()) return false;
    await file.parent.create(recursive: true);
    await file.writeAsString('');
    return true;
  }

  /// Write [dictionary], creating the directory and file when absent.
  ///
  /// **A running `anthy-agent` will not see this.** The agent reads the
  /// personal dictionary once at startup, so a caller that wants the new word
  /// available immediately must restart its agent — for a
  /// `PreeditSession`/`ImeController` stack that means disposing and rebuilding
  /// the controller.
  Future<void> save(AnthyUserDictionary dictionary) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(dictionary.render(), flush: true);
  }

  /// Load, add [word], and save — the whole "register this word" operation.
  /// Returns the saved dictionary.
  Future<AnthyUserDictionary> addWord(AnthyUserWord word) async {
    final AnthyUserDictionary next = (await load()).withWord(word);
    await save(next);
    return next;
  }

  /// Load, remove [word], and save. Returns the saved dictionary.
  Future<AnthyUserDictionary> removeWord(AnthyUserWord word) async {
    final AnthyUserDictionary next = (await load()).withoutWord(word);
    await save(next);
    return next;
  }
}
