/// Browser [HostEnv] — an empty environment, stated plainly.
///
/// Every getter here returns the honest browser answer rather than a plausible
/// desktop-shaped lie. [home] is null, not `'/home/user'`; [environment] is
/// empty, not a synthesized `{'HOME': '/'}`. Callers that need a home directory
/// must therefore handle its absence, which is exactly the code path a browser
/// host needs them to take.
library;

import 'host_env.dart';

/// Returns the browser environment.
HostEnv createHostEnv() => const WebHostEnv();

/// [HostEnv] for a browser: no variables, no processes, no home.
class WebHostEnv implements HostEnv {
  /// Creates the browser environment.
  const WebHostEnv();

  @override
  Map<String, String> get environment => const <String, String>{};

  @override
  String? operator [](String name) => null;

  /// `/` — the separator the browser host's synthetic paths use.
  @override
  String get pathSeparator => '/';

  @override
  HostOs get os => HostOs.web;

  @override
  bool get hasProcesses => false;

  /// Always null. A browser has no home directory, and inventing one would
  /// make `collapseTilde` and path completion produce paths that resolve
  /// nowhere.
  @override
  String? get home => null;
}
