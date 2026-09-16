/// Host font enumeration on `dart:io` platforms.
///
/// Isolated here for two reasons, not one: `Process.run` needs `dart:io`, and
/// the off-thread parse needs `dart:isolate` — which is *also* absent on web
/// and is the less obvious of the two blockers.
library;

import 'dart:io';
import 'dart:isolate';

import 'font_parsing.dart';

/// True when [exe] resolves on the current PATH (handles the Windows `;`
/// separator and executable extensions).
bool isOnPath(String exe) {
  final String path = Platform.environment['PATH'] ?? '';
  final String sep = Platform.isWindows ? ';' : ':';
  final List<String> exts = Platform.isWindows
      ? const <String>['.exe', '.com', '.bat', '']
      : const <String>[''];
  for (final String dir in path.split(sep)) {
    if (dir.isEmpty) continue;
    for (final String ext in exts) {
      if (File('$dir${Platform.pathSeparator}$exe$ext').existsSync()) {
        return true;
      }
    }
  }
  return false;
}

/// Enumerate installed font families via `fc-list`, or return an empty list
/// when unavailable.
///
/// Linux-only: `fc-list` is the fontconfig CLI. Output can run to thousands of
/// lines, so the parse is pushed off the UI isolate with [Isolate.run].
Future<List<String>> enumerateHostFontFamilies() async {
  try {
    if (Platform.isLinux && isOnPath('fc-list')) {
      final ProcessResult result =
          await Process.run('fc-list', <String>[': family']);
      if (result.exitCode == 0) {
        final String raw = result.stdout as String;
        return Isolate.run(() => parseFcList(raw));
      }
    }
  } catch (_) {
    // Any failure means "no enumeration"; the caller falls back to the
    // curated list.
  }
  return const <String>[];
}
