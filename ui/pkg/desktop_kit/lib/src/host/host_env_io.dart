/// `dart:io`-backed [HostEnv] — the real process environment.
library;

import 'dart:io';

import 'host_env.dart';

/// Returns the live process environment.
HostEnv createHostEnv() => const IoHostEnv();

/// [HostEnv] over `Platform` and the real process environment.
class IoHostEnv implements HostEnv {
  /// Creates the io-backed environment.
  const IoHostEnv();

  @override
  Map<String, String> get environment => Platform.environment;

  @override
  String? operator [](String name) => Platform.environment[name];

  @override
  String get pathSeparator => Platform.pathSeparator;

  @override
  HostOs get os {
    if (Platform.isLinux) return HostOs.linux;
    if (Platform.isMacOS) return HostOs.macos;
    if (Platform.isWindows) return HostOs.windows;
    if (Platform.isAndroid) return HostOs.android;
    if (Platform.isIOS) return HostOs.ios;
    return HostOs.unknown;
  }

  @override
  bool get hasProcesses => !Platform.isAndroid && !Platform.isIOS;

  @override
  String? get home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
}
