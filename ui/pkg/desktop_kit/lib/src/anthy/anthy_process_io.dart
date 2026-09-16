/// Subprocess-backed [AnthyProcess] — `dart:io` only.
///
/// Split out of `anthy_process.dart` so the interface stays web-compilable.
/// Reach it through the `desktop_kit_anthy_io.dart` entrypoint.
library;

import 'dart:convert';
import 'dart:io';

import 'anthy_process.dart';

/// Signature for spawning a [Process] — injectable so tests can substitute a
/// fake spawn without touching the real binary.
typedef ProcessSpawner = Future<Process> Function(
    String executable, List<String> arguments);

/// Real [AnthyProcess] backed by a spawned `anthy-agent --egg` subprocess.
///
/// stdin and stdout are both UTF-8 (the egg protocol is UTF-8 throughout,
/// negotiated via `NEW-CONTEXT INPUT=#18 OUTPUT=#18`). The decoded stdout is
/// split on `\n` and each line has a trailing `\r` trimmed so callers never
/// have to think about wire framing.
class SystemAnthyProcess implements AnthyProcess {
  SystemAnthyProcess._(this._process) {
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(_trimCr);
  }

  /// Default name of the agent executable (resolved via PATH).
  ///
  /// Re-exposed as a static for source compatibility; the canonical constant is
  /// [anthyExecutableName] in `anthy_process.dart`.
  static const String executableName = anthyExecutableName;

  /// Arguments that put the agent into egg-protocol mode.
  static const List<String> eggArguments = anthyEggArguments;

  final Process _process;
  late final Stream<String> _stdout;
  bool _killed = false;

  /// Spawn the agent. [executable] defaults to `anthy-agent` (PATH lookup);
  /// override it to point at a specific binary. [spawn] is injectable so tests
  /// can supply a fake [Process] without launching anything; it defaults to
  /// [Process.start].
  static Future<SystemAnthyProcess> start({
    String executable = executableName,
    ProcessSpawner? spawn,
  }) async {
    final ProcessSpawner spawner = spawn ?? _defaultSpawn;
    final Process process = await spawner(executable, eggArguments);
    return SystemAnthyProcess._(process);
  }

  static Future<Process> _defaultSpawn(
    String executable,
    List<String> arguments,
  ) {
    return Process.start(executable, arguments);
  }

  @override
  Stream<String> get lines => _stdout;

  @override
  void send(String line) {
    _process.stdin.add(utf8.encode('$line\n'));
  }

  @override
  Future<void> kill() async {
    if (_killed) return;
    _killed = true;
    _process.kill(ProcessSignal.sigterm);
    // Drain stdin best-effort; ignore errors if the pipe is already closed.
    try {
      await _process.stdin.close();
    } catch (_) {
      // Process already exited / pipe closed — nothing to flush.
    }
  }

  static String _trimCr(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
}
