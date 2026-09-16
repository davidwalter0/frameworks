/// Storage backend behind [SettingsStore] — the seam that lets settings
/// persist on a host with no filesystem.
///
/// `SettingsStore` used to reach for `dart:io` and `path_provider` directly,
/// which made it a compile-time blocker for the web target: `path_provider`
/// declares no web implementation at all (its plugin platform map lists only
/// android/ios/linux/macos/windows), so the import alone sank the build.
///
/// The store now speaks to this interface, and the concrete backend is chosen
/// by conditional import — file-backed under `dart:io`, `localStorage`-backed
/// under `dart:js_interop`, and an in-memory stub anywhere else.
library;

/// Reads and writes one opaque settings blob.
///
/// Implementations must never throw: a missing or unreadable store reports as
/// `null` from [read], and a failed [write] is swallowed after being reported
/// through [SettingsStore]'s debug output. Settings are a convenience, and
/// losing them must never take the editor down with them.
abstract class SettingsBackend {
  /// The stored blob, or null when nothing has been written yet.
  Future<String?> read();

  /// Replaces the stored blob with [contents].
  Future<void> write(String contents);

  /// Human-readable location for diagnostics and the host help screen — a
  /// filesystem path, a `localStorage` key, or `<memory>`.
  String get location;

  /// False when writes are discarded (the in-memory stub), so a host can grade
  /// [HostCapability.persistentSettings] honestly rather than promising
  /// persistence it does not have.
  bool get persists;
}

/// A backend that keeps settings only for the lifetime of the process.
///
/// Used as the fallback on hosts with neither a filesystem nor web storage,
/// and directly useful in tests. [persists] is false so callers can tell the
/// difference between "saved" and "saved nowhere".
class MemorySettingsBackend implements SettingsBackend {
  /// Creates an in-memory backend, optionally seeded with [initial].
  MemorySettingsBackend({String? initial}) : _blob = initial;

  String? _blob;

  @override
  Future<String?> read() async => _blob;

  @override
  Future<void> write(String contents) async => _blob = contents;

  @override
  String get location => '<memory>';

  @override
  bool get persists => false;
}
