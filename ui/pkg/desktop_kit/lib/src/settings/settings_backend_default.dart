/// Resolves the platform-appropriate [SettingsBackend] by conditional import.
///
/// Resolution order — the first satisfied condition wins, and the bare
/// `settings_backend_stub.dart` is the default when none is:
///
/// | Condition | Backend | Persists |
/// |---|---|---|
/// | `dart.library.io` | file under the platform config dir | yes |
/// | `dart.library.js_interop` | `localStorage` | yes |
/// | neither | in-memory | no |
///
/// Importing this file — rather than a concrete backend — is what keeps
/// `settings_store.dart` free of `dart:io`, and therefore compilable for web.
library;

export 'settings_backend_stub.dart'
    if (dart.library.io) 'settings_backend_io.dart'
    if (dart.library.js_interop) 'settings_backend_web.dart';
