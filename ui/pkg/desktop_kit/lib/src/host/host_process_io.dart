/// `dart:io`-backed subprocess execution.
library;

import 'dart:io';

import 'host_process.dart';

/// Runs [exe] with [args], optionally writing [stdin] to its input.
///
/// `Process.run` has no stdin parameter, so the stdin path goes through
/// `Process.start` and drains both output streams before awaiting exit —
/// draining first avoids the deadlock where a child blocks writing to a full
/// pipe while the parent blocks on `exitCode`.
Future<HostProcessResult> runHostProcess(
  String exe,
  List<String> args, {
  String? stdin,
}) async {
  if (stdin == null) {
    final ProcessResult r = await Process.run(exe, args);
    return HostProcessResult(
      exitCode: r.exitCode,
      stdout: r.stdout as String,
      stderr: r.stderr as String,
    );
  }

  final Process process = await Process.start(exe, args);
  process.stdin.write(stdin);
  await process.stdin.close();
  final List<int> out =
      await process.stdout.expand((List<int> l) => l).toList();
  final List<int> err =
      await process.stderr.expand((List<int> l) => l).toList();
  final int exitCode = await process.exitCode;
  return HostProcessResult(
    exitCode: exitCode,
    stdout: String.fromCharCodes(out),
    stderr: String.fromCharCodes(err),
  );
}

/// True when [exe] resolves via `which` (POSIX) or `where` (Windows).
Future<bool> hostExecutableExists(String exe) async {
  try {
    final ProcessResult r = Platform.isWindows
        ? await Process.run('where', <String>[exe])
        : await Process.run('which', <String>[exe]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
