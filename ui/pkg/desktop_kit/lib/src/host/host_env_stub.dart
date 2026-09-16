/// Fallback [HostEnv] for targets satisfying neither conditional-import branch.
///
/// Behaves like the browser environment: empty, honest, and process-free.
library;

import 'host_env.dart';

/// Returns the stub environment.
HostEnv createHostEnv() => const StubHostEnv();

/// An empty [HostEnv] for hosts with no environment to report.
class StubHostEnv implements HostEnv {
  /// Creates the stub environment.
  const StubHostEnv();

  @override
  Map<String, String> get environment => const <String, String>{};

  @override
  String? operator [](String name) => null;

  @override
  String get pathSeparator => '/';

  @override
  HostOs get os => HostOs.unknown;

  @override
  bool get hasProcesses => false;

  @override
  String? get home => null;
}
