/// Host environment access, without `dart:io`.
///
/// Four kit libraries needed `Platform.environment`, `Platform.isLinux` or
/// `Platform.pathSeparator` for otherwise-pure work — collapsing a `$HOME`
/// prefix, picking a font fallback list, choosing a clipboard tool. Each one
/// dragged `dart:io` into its library and, transitively, into every entrypoint
/// that exported it.
///
/// This is the single seam they share instead. The implementation is chosen by
/// conditional import (see `host_env_default.dart`); everything above it stays
/// pure and web-compilable.
library;

/// Which kind of host the app is running on.
///
/// `web` is deliberately a peer of the desktop platforms rather than a flag on
/// top of them: on web there is no `Platform.operatingSystem` to consult, and
/// code that branches on "is it Linux" nearly always means "does it have Linux
/// facilities", which the browser does not regardless of the underlying OS.
enum HostOs {
  /// Linux desktop.
  linux,

  /// macOS desktop.
  macos,

  /// Microsoft Windows desktop.
  windows,

  /// Android.
  android,

  /// iOS.
  ios,

  /// A browser — no process environment, no path namespace.
  web,

  /// Anything else, including test environments.
  unknown;

  /// The tag used by the font fallback tables — `'macos'`, `'windows'`,
  /// `'linux'`, or `'other'`.
  String get fontTag => switch (this) {
        HostOs.macos => 'macos',
        HostOs.windows => 'windows',
        HostOs.linux => 'linux',
        _ => 'other',
      };
}

/// The environment a host exposes.
///
/// Implementations are trivial on `dart:io` hosts and near-empty on the web,
/// which is the point: callers get a total interface and branch on the values,
/// not on which platform they think they are.
abstract class HostEnv {
  /// All environment variables, or an empty map on hosts without a process
  /// environment.
  Map<String, String> get environment;

  /// The value of [name], or null when unset or unavailable.
  String? operator [](String name);

  /// The host's path separator — `/` or `\`. Web hosts report `/`, which is
  /// what their synthetic paths use.
  String get pathSeparator;

  /// Which platform this is.
  HostOs get os;

  /// True when the host can spawn subprocesses at all. False in every browser.
  bool get hasProcesses;

  /// The user's home directory, or null when the host has no such concept.
  String? get home;
}
