/// `localStorage`-backed [SettingsBackend] for browser hosts.
///
/// Settings are small, JSON, and written on a 300 ms debounce, which is
/// exactly the shape `localStorage` handles well. IndexedDB would lift the
/// size ceiling but costs an async open, a schema, and a migration path for
/// something that is a few kilobytes of preferences.
///
/// The tradeoff is declared rather than hidden: the browser host grades
/// `HostCapability.persistentSettings` as `degraded` and says "localStorage,
/// ~5 MB, cleared when site data is cleared" — see `browser_host.dart`.
library;

import 'package:web/web.dart' as web;

import 'settings_backend.dart';

/// Creates the `localStorage` backend. Shares its signature with the io and
/// stub variants so the conditional import resolves to one call shape.
SettingsBackend createSettingsBackend({
  required String appId,
  required String fileName,
  String? overridePath,
}) =>
    WebSettingsBackend(appId: appId, fileName: fileName);

/// Persists the settings blob under a single `localStorage` key.
///
/// The key is namespaced `desktop_kit/<appId>/<fileName>` so several apps —
/// and several config files within one app — can share an origin without
/// colliding. `overridePath` is accepted by [createSettingsBackend] for
/// signature parity and ignored here; browsers have no directory to point at.
class WebSettingsBackend implements SettingsBackend {
  /// Creates a backend writing to the key for [appId] / [fileName].
  WebSettingsBackend({required String appId, required String fileName})
      : _key = 'desktop_kit/$appId/$fileName';

  final String _key;

  @override
  Future<String?> read() async => web.window.localStorage.getItem(_key);

  @override
  Future<void> write(String contents) async =>
      web.window.localStorage.setItem(_key, contents);

  @override
  String get location => 'localStorage[$_key]';

  @override
  bool get persists => true;
}
