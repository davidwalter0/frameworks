/// File-backed [SettingsBackend] for hosts with a real filesystem.
///
/// Path convention (unchanged from the pre-web `SettingsStore`):
///
/// | Platform | Path |
/// |---|---|
/// | Linux | `${XDG_CONFIG_HOME:-~/.config}/<appId>/<fileName>` |
/// | macOS / Windows | `<ApplicationSupportDir>/<appId>/<fileName>` |
/// | Android | `<ApplicationDocumentsDir>/<appId>/<fileName>` |
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'settings_backend.dart';

/// Creates the file-backed backend. Signature is shared with the web and stub
/// variants so the conditional import in `settings_backend_default.dart`
/// resolves to a single call shape.
///
/// [overridePath] pins the containing directory (tests point it at a temp dir);
/// it replaces the old `overrideDir: Directory?` parameter, which could not
/// appear in a web-compiled signature because `Directory` is a `dart:io` type.
SettingsBackend createSettingsBackend({
  required String appId,
  required String fileName,
  String? overridePath,
}) =>
    FileSettingsBackend(
      appId: appId,
      fileName: fileName,
      overridePath: overridePath,
    );

/// Persists the settings blob to a platform-appropriate config file.
class FileSettingsBackend implements SettingsBackend {
  /// Creates a file backend for [appId] / [fileName], optionally pinned to
  /// [overridePath].
  FileSettingsBackend({
    required String appId,
    required String fileName,
    String? overridePath,
  })  : _appId = appId,
        _fileName = fileName,
        _overridePath = overridePath;

  final String _appId;
  final String _fileName;
  final String? _overridePath;

  File? _cached;
  String _location = '<unresolved>';

  Future<File> get _file async => _cached ??= await _resolve();

  Future<File> _resolve() async {
    final File file = await _resolveUncached();
    _location = file.path;
    return file;
  }

  Future<File> _resolveUncached() async {
    final String? override = _overridePath;
    if (override != null) {
      return File('$override${Platform.pathSeparator}$_fileName');
    }

    if (Platform.isLinux) {
      final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
      final String configHome = (xdg != null && xdg.isNotEmpty)
          ? xdg
          : '${Platform.environment['HOME'] ?? ''}/.config';
      return File('$configHome/$_appId/$_fileName');
    }

    if (Platform.isAndroid) {
      final Directory dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/$_appId/$_fileName');
    }

    // macOS: ~/Library/Application Support/<bundleId>/<appId>/<fileName>
    // Windows: %APPDATA%\<packageName>\<appId>\<fileName>
    final Directory dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_appId/$_fileName');
  }

  @override
  Future<String?> read() async {
    final File file = await _file;
    if (!file.existsSync()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String contents) async {
    final File file = await _file;
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  @override
  String get location => _location;

  @override
  bool get persists => true;
}
