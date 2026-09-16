/// Resolves host font enumeration by conditional import.
///
/// | Condition | Enumeration |
/// |---|---|
/// | `dart.library.io` | `fc-list` on Linux, parsed off-isolate |
/// | `dart.library.js_interop` | none — browsers do not expose font lists |
/// | neither | none |
library;

export 'font_enumeration_web.dart'
    if (dart.library.io) 'font_enumeration_io.dart'
    if (dart.library.js_interop) 'font_enumeration_web.dart';
