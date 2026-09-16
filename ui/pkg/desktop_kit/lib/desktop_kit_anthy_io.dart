/// Subprocess-backed Anthy transport, and personal-dictionary file I/O —
/// `dart:io` platforms only.
///
/// Kept out of `desktop_kit_anthy.dart` so that entrypoint stays
/// web-compilable: the driver, protocol and controller work anywhere, and only
/// the process spawn is platform-bound. A web build imports the driver from
/// `desktop_kit_anthy.dart` and supplies its own [AnthyProcess] — or, in
/// browser mode with no backend, none at all.
///
/// Importing this library from code that also builds for web is a compile
/// error, which is the intended failure: it names the platform assumption at
/// the import site rather than at runtime.
library;

export 'src/anthy/anthy_process_io.dart';
export 'src/anthy/anthy_user_dictionary_io.dart';
