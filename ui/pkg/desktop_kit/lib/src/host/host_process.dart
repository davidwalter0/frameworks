/// Subprocess seam, without `dart:io` types in the public signature.
///
/// `primary_selection.dart` exposed a `ProcessRunner` typedef returning
/// `ProcessResult`, and `anthy_process.dart` a `ProcessSpawner` returning
/// `Process`. Both are `dart:io` types, so both typedefs were uncompilable for
/// web even though the surrounding logic — session detection, tool choice,
/// protocol framing — is pure.
///
/// [HostProcessResult] is the kit-owned stand-in. It carries exactly what the
/// callers read (exit code, decoded stdout/stderr) and nothing that binds it to
/// a platform.
library;

/// The outcome of a one-shot subprocess.
class HostProcessResult {
  /// Creates a result.
  const HostProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Process exit status; 0 conventionally means success.
  final int exitCode;

  /// Decoded standard output.
  final String stdout;

  /// Decoded standard error.
  final String stderr;

  /// True when [exitCode] is zero.
  bool get ok => exitCode == 0;
}

/// Signature for running a subprocess, injectable so tests substitute a fake.
typedef HostProcessRunner = Future<HostProcessResult> Function(
  String exe,
  List<String> args, {
  String? stdin,
});

/// Signature for probing whether [exe] is available on the host.
typedef HostPathProbe = Future<bool> Function(String exe);

/// Thrown when subprocess execution is attempted on a host that has none.
///
/// Callers that can degrade should probe [HostEnv.hasProcesses] or use a path
/// probe (which reports false on such hosts) rather than catching this — an
/// exception is the backstop for code that assumed a process host, not the
/// intended control flow.
class HostProcessUnsupported implements Exception {
  /// Creates the error for an attempted [executable] launch.
  const HostProcessUnsupported(this.executable);

  /// The executable the caller tried to run.
  final String executable;

  @override
  String toString() =>
      'HostProcessUnsupported: cannot run "$executable" — this host has no '
      'process facility. In a browser, run the app against a local backend '
      '(remote mode) if this feature is required.';
}
