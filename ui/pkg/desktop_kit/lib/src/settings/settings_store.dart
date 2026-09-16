// Generic, reusable settings persistence store for desktop_kit.
//
// Storage is delegated to a [SettingsBackend] chosen by conditional import
// (see settings_backend_default.dart), so this library holds no `dart:io`
// import and compiles for web:
//
//   Linux   : ${XDG_CONFIG_HOME:-~/.config}/<appId>/<fileName>
//   macOS   : <ApplicationSupportDir>/<appId>/<fileName>
//   Windows : <ApplicationSupportDir>/<appId>/<fileName>
//   Android : <ApplicationDocumentsDir>/<appId>/<fileName>
//   Web     : localStorage['desktop_kit/<appId>/<fileName>']
//
// Saves are debounced (300 ms) so rapid UI interactions coalesce into one
// write. A [savedAt] notifier is stamped after each successful write so the
// UI can display a "Saved ✓" flash.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'settings_backend.dart';
import 'settings_backend_default.dart';

/// Persists arbitrary JSON maps through a platform-appropriate
/// [SettingsBackend].
///
/// ### Construction
///
/// ```dart
/// // Typical use — one instance per app:
/// final store = SettingsStore(appId: 'my_app');
///
/// // Test use — pin the directory so no real config tree is touched:
/// final store = SettingsStore(appId: 'my_app', overridePath: tmpDir.path);
///
/// // Full control (tests, or a host with bespoke storage):
/// final store = SettingsStore(appId: 'my_app', backend: MemorySettingsBackend());
/// ```
///
/// ### Storage convention
///
/// | Platform | Location |
/// |---|---|
/// | Linux | `${XDG_CONFIG_HOME:-~/.config}/<appId>/<fileName>` |
/// | macOS / Windows | `<ApplicationSupportDir>/<appId>/<fileName>` |
/// | Android | `<ApplicationDocumentsDir>/<appId>/<fileName>` |
/// | Web | `localStorage['desktop_kit/<appId>/<fileName>']` |
///
/// ### Save contract
///
/// - [scheduleSave] debounces 300 ms; rapid bursts collapse to one write.
/// - [flush] writes immediately (use in tests or on app-close).
/// - [savedAt] is stamped after every successful write.
class SettingsStore {
  /// Creates a [SettingsStore] for the given application.
  ///
  /// [appId] is used as a path (or key) segment — it should be a stable,
  /// lowercase, hyphen-separated identifier (e.g. `'alert-log'`).
  ///
  /// [fileName] defaults to `'config.json'`; override when an app stores
  /// multiple independent config files.
  ///
  /// [overridePath] pins the containing directory on filesystem hosts (useful
  /// in tests to write into a temp location instead of the real config tree).
  /// It is ignored by backends with no directory namespace, such as the web
  /// `localStorage` backend.
  ///
  /// [backend] replaces the conditionally-imported default outright, for tests
  /// or a host with its own storage.
  ///
  /// > Migration note: this parameter was `overrideDir: Directory?` before the
  /// > web target existed. `Directory` is a `dart:io` type, so its presence in
  /// > the signature made every consumer of this library uncompilable for web
  /// > — it is a `String` path now for that reason.
  SettingsStore({
    required String appId,
    String fileName = 'config.json',
    String? overridePath,
    SettingsBackend? backend,
  })  : _appId = appId,
        _backend = backend ??
            createSettingsBackend(
              appId: appId,
              fileName: fileName,
              overridePath: overridePath,
            );

  final String _appId;
  final SettingsBackend _backend;

  Timer? _debounce;

  /// Notified (with the write timestamp) after each successful write.
  ///
  /// Listen to this in a [ValueListenableBuilder] or [SavedIndicator] to show
  /// a "Saved ✓" flash in the UI.
  final ValueNotifier<DateTime?> savedAt = ValueNotifier<DateTime?>(null);

  /// Where this store persists, for diagnostics and the host help screen —
  /// a file path, a `localStorage` key, or `<memory>`.
  String get location => _backend.location;

  /// False when writes are discarded (the in-memory fallback), so a caller can
  /// report "settings will not survive a restart" instead of implying they will.
  bool get persists => _backend.persists;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Loads the config and returns it as a raw map.
  ///
  /// Returns `{}` on any failure — missing store, corrupt JSON, wrong type —
  /// and never throws. The caller is responsible for interpreting the map
  /// (typically via a typed model's `fromMap` factory).
  Future<Map<String, dynamic>> load() async {
    try {
      final String? raw = await _backend.read();
      if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
      return decoded;
    } catch (e) {
      debugPrint('[SettingsStore:$_appId] load error (returning {}): $e');
      return <String, dynamic>{};
    }
  }

  /// Schedules a debounced write (~300 ms).
  ///
  /// Multiple calls within the debounce window collapse into a single write,
  /// so rapid slider drags or text-field updates stay cheap.
  void scheduleSave(Map<String, dynamic> data) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _write(data));
  }

  /// Writes [data] immediately.
  ///
  /// Use this in tests (to avoid waiting for the debounce timer) and on
  /// app-close / `dispose` to flush any pending changes.
  Future<void> flush(Map<String, dynamic> data) async {
    _debounce?.cancel();
    await _write(data);
  }

  // ── Private write ─────────────────────────────────────────────────────────

  Future<void> _write(Map<String, dynamic> data) async {
    try {
      await _backend.write(const JsonEncoder.withIndent('  ').convert(data));
      savedAt.value = DateTime.now();
    } catch (e) {
      debugPrint('[SettingsStore:$_appId] save error: $e');
    }
  }
}
