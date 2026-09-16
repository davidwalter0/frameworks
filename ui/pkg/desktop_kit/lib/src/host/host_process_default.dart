/// Resolves subprocess execution by conditional import.
///
/// | Condition | Behaviour |
/// |---|---|
/// | `dart.library.io` | real `Process.run` / `Process.start` |
/// | `dart.library.js_interop` | probe returns false; run throws |
/// | neither | same as web |
library;

export 'host_process.dart';
export 'host_process_web.dart'
    if (dart.library.io) 'host_process_io.dart'
    if (dart.library.js_interop) 'host_process_web.dart';
