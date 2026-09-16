import 'package:desktop_kit/desktop_kit_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake ProcessRunner infrastructure
// ---------------------------------------------------------------------------

/// A record of one subprocess call made by [PrimarySelection].
class _Call {
  _Call(this.exe, this.args, {this.stdin});

  /// The executable name.
  final String exe;

  /// Arguments passed to the executable.
  final List<String> args;

  /// The stdin text provided (null when the runner was called without stdin).
  final String? stdin;

  @override
  String toString() =>
      '$exe ${args.join(' ')}${stdin != null ? ' <"$stdin"' : ''}';
}

/// Builds a fake [ProcessRunner] that records every call and returns a
/// configurable [HostProcessResult].
///
/// [readOutput] is returned as stdout for read calls; the default is
/// `'selected text'`.
/// [exitCode] lets tests simulate tool failure.
({ProcessRunner runner, List<_Call> calls}) makeFakeRunner({
  String readOutput = 'selected text',
  int exitCode = 0,
}) {
  final List<_Call> calls = [];

  Future<HostProcessResult> runner(
    String exe,
    List<String> args, {
    String? stdin,
  }) async {
    calls.add(_Call(exe, args, stdin: stdin));
    return HostProcessResult(
        exitCode: exitCode, stdout: readOutput, stderr: '');
  }

  return (runner: runner, calls: calls);
}

/// PATH probe that returns `true` for the given set of executables.
Future<bool> Function(String) probeFor(Iterable<String> available) {
  final Set<String> set = available.toSet();
  return (String exe) async => set.contains(exe);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Wayland session
  // -------------------------------------------------------------------------

  group('PrimarySelection — Wayland', () {
    final Map<String, String> waylandEnv = {
      'XDG_SESSION_TYPE': 'wayland',
    };

    test('write: calls wl-copy --primary with text on stdin', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor(['wl-copy', 'wl-paste']),
      );

      await primary.write('hello wayland');

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'wl-copy');
      expect(calls.first.args, ['--primary']);
      expect(calls.first.stdin, 'hello wayland');
    });

    test('read: calls wl-paste --primary -n and returns trimmed stdout',
        () async {
      final (:runner, :calls) = makeFakeRunner(readOutput: 'pasted text\n');
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor(['wl-copy', 'wl-paste']),
      );

      final String? result = await primary.read();

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'wl-paste');
      expect(calls.first.args, ['--primary', '-n']);
      expect(result, 'pasted text');
    });

    test('read: returns null when wl-paste exits non-zero', () async {
      final (:runner, :calls) = makeFakeRunner(exitCode: 1);
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor(['wl-copy', 'wl-paste']),
      );

      final String? result = await primary.read();

      expect(calls, hasLength(1));
      expect(result, isNull);
    });

    test('isSupported: false when wl-copy absent; hint mentions wl-clipboard',
        () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor([]), // nothing on PATH
      );

      expect(await primary.isSupported, isFalse);
      expect(primary.missingToolHint, contains('wl-clipboard'));
      expect(calls, isEmpty); // no subprocess on missing tool
    });

    test('write: silent no-op when tool absent (does not throw)', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor([]),
      );

      // Must not throw.
      await expectLater(primary.write('text'), completes);
      expect(calls, isEmpty);
    });

    test('read: returns null when tool absent (does not throw)', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: waylandEnv,
        pathProbe: probeFor([]),
      );

      final String? result = await primary.read();
      expect(result, isNull);
      expect(calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // X11 session — xclip preferred
  // -------------------------------------------------------------------------

  group('PrimarySelection — X11 (xclip preferred)', () {
    final Map<String, String> x11Env = {
      'XDG_SESSION_TYPE': 'x11',
      'DISPLAY': ':0',
    };

    test('write: calls xclip -selection primary with text on stdin', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: x11Env,
        pathProbe: probeFor(['xclip', 'xsel']),
      );

      await primary.write('hello x11');

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'xclip');
      expect(calls.first.args, ['-selection', 'primary']);
      expect(calls.first.stdin, 'hello x11');
    });

    test('read: calls xclip -o -selection primary and returns stdout',
        () async {
      final (:runner, :calls) = makeFakeRunner(readOutput: 'clip content');
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: x11Env,
        pathProbe: probeFor(['xclip', 'xsel']),
      );

      final String? result = await primary.read();

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'xclip');
      expect(calls.first.args, ['-o', '-selection', 'primary']);
      expect(result, 'clip content');
    });
  });

  // -------------------------------------------------------------------------
  // X11 session — xsel fallback
  // -------------------------------------------------------------------------

  group('PrimarySelection — X11 (xsel fallback)', () {
    final Map<String, String> x11Env = {
      'XDG_SESSION_TYPE': 'x11',
      'DISPLAY': ':0',
    };

    test('write: falls back to xsel --primary --input when xclip absent',
        () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: x11Env,
        pathProbe: probeFor(['xsel']), // no xclip
      );

      await primary.write('xsel text');

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'xsel');
      expect(calls.first.args, ['--primary', '--input']);
      expect(calls.first.stdin, 'xsel text');
    });

    test('read: falls back to xsel --primary --output when xclip absent',
        () async {
      final (:runner, :calls) = makeFakeRunner(readOutput: 'xsel content');
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: x11Env,
        pathProbe: probeFor(['xsel']),
      );

      final String? result = await primary.read();

      expect(calls, hasLength(1));
      expect(calls.first.exe, 'xsel');
      expect(calls.first.args, ['--primary', '--output']);
      expect(result, 'xsel content');
    });

    test('isSupported: false when neither xclip nor xsel present', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: x11Env,
        pathProbe: probeFor([]),
      );

      expect(await primary.isSupported, isFalse);
      expect(primary.missingToolHint, contains('xclip'));
      expect(primary.missingToolHint, contains('xsel'));
      expect(calls, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // XWayland session (Wayland session but DISPLAY set → X11 tools)
  // -------------------------------------------------------------------------

  group('PrimarySelection — XWayland (Wayland + DISPLAY → X11 tools)', () {
    final Map<String, String> xwaylandEnv = {
      'XDG_SESSION_TYPE': 'wayland',
      'WAYLAND_DISPLAY': 'wayland-0',
      'DISPLAY': ':1',
    };

    test('uses xclip (X11 tool) even though XDG_SESSION_TYPE=wayland',
        () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: xwaylandEnv,
        pathProbe: probeFor(['xclip']),
      );

      await primary.write('xwayland text');

      expect(calls.first.exe, 'xclip');
    });
  });

  // -------------------------------------------------------------------------
  // Unknown session
  // -------------------------------------------------------------------------

  group('PrimarySelection — unknown session', () {
    test('still tries xclip/xsel; hint mentions both tools', () async {
      final (:runner, :calls) = makeFakeRunner();
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: {}, // no env vars at all → unknown session
        pathProbe: probeFor([]),
      );

      expect(await primary.isSupported, isFalse);
      expect(primary.missingToolHint, contains('xclip'));
      expect(primary.missingToolHint, contains('xsel'));
      expect(calls, isEmpty);
    });

    test('write/read work when xsel available on unknown session', () async {
      final (:runner, :calls) = makeFakeRunner(readOutput: 'data');
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: {},
        pathProbe: probeFor(['xsel']),
      );

      await primary.write('data');
      expect(calls.last.exe, 'xsel');
      expect(calls.last.args, ['--primary', '--input']);

      final String? result = await primary.read();
      expect(result, 'data');
      expect(calls.last.exe, 'xsel');
      expect(calls.last.args, ['--primary', '--output']);
    });
  });

  // -------------------------------------------------------------------------
  // read returns null on empty output
  // -------------------------------------------------------------------------

  group('PrimarySelection.read edge cases', () {
    test('returns null when tool output is whitespace-only', () async {
      final (:runner, :calls) = makeFakeRunner(readOutput: '   \n');
      final PrimarySelection primary = PrimarySelection(
        processRunner: runner,
        env: {'XDG_SESSION_TYPE': 'x11', 'DISPLAY': ':0'},
        pathProbe: probeFor(['xclip']),
      );

      final String? result = await primary.read();
      expect(result, isNull);
      expect(calls, hasLength(1));
    });
  });
}
