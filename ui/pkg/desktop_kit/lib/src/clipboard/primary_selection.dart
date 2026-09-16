/// PRIMARY selection support for Linux (X11 and Wayland).
///
/// The PRIMARY selection is the "highlight to copy, middle-click to paste"
/// mechanism that all native Linux apps speak.  Flutter's [Clipboard] API
/// covers only the CLIPBOARD selection (Ctrl+C/V); this library fills the gap
/// via subprocess calls to the standard CLI tools.
///
/// ### Typical usage
///
/// ```dart
/// final primary = PrimarySelection();
///
/// // In your text-selection callback:
/// void onSelectionChanged(String selectedText) {
///   primary.write(selectedText); // auto-copies highlighted text → PRIMARY
/// }
///
/// // In your middle-click handler (via [middleClickPaste]):
/// Future<void> handleMiddleClick() async {
///   final text = await primary.read();
///   if (text != null) insertAtCursor(text);
/// }
/// ```
library;

import 'package:flutter/widgets.dart';

import '../host/host_env_default.dart';
import '../host/host_process_default.dart';

export '../host/host_process.dart' show HostProcessResult;

/// Discriminates the Linux session type so the right CLI tool is chosen.
enum LinuxSession {
  /// A native Wayland compositor is running (`XDG_SESSION_TYPE=wayland` and
  /// no `DISPLAY` env var — i.e. no XWayland).
  wayland,

  /// An X11 session, or Wayland with XWayland active.  A Flutter app running
  /// under XWayland is technically an X11 client, so X11 tools apply.
  x11,

  /// Session type could not be determined from the environment.
  unknown,
}

/// Detects the Linux desktop session type from environment variables.
///
/// Detection rules (applied in order):
/// 1. `XDG_SESSION_TYPE == 'wayland'` **and** `DISPLAY` is absent or empty
///    → [LinuxSession.wayland] (pure Wayland, no XWayland active).
/// 2. `XDG_SESSION_TYPE == 'wayland'` **and** `DISPLAY` is set (XWayland) →
///    [LinuxSession.x11] (Flutter is an X11 client under XWayland; use X11
///    tools).
/// 3. `XDG_SESSION_TYPE == 'x11'` or `DISPLAY` is set (non-empty) →
///    [LinuxSession.x11].
/// 4. Otherwise → [LinuxSession.unknown].
///
/// The [env] parameter is injectable so unit tests can exercise all branches
/// without touching the live environment.  Pass `null` (the default) to use
/// the host process environment — which is empty in a browser, so detection
/// lands on [LinuxSession.unknown] and the tool probe then reports no tool.
LinuxSession detectLinuxSession({Map<String, String>? env}) {
  final Map<String, String> e = env ?? hostEnv.environment;
  final String? xdgType = e['XDG_SESSION_TYPE'];
  final String display = e['DISPLAY'] ?? '';
  final String waylandDisplay = e['WAYLAND_DISPLAY'] ?? '';

  if (xdgType == 'wayland' && display.isEmpty) {
    return LinuxSession.wayland;
  }
  if (xdgType == 'wayland' && display.isNotEmpty) {
    // XWayland is active; the Flutter GTK embedder is an X11 client.
    return LinuxSession.x11;
  }
  if (xdgType == 'x11' || display.isNotEmpty) {
    return LinuxSession.x11;
  }
  // WAYLAND_DISPLAY without XDG_SESSION_TYPE is a less-common but valid
  // indicator of a Wayland session.
  if (waylandDisplay.isNotEmpty && display.isEmpty) {
    return LinuxSession.wayland;
  }
  return LinuxSession.unknown;
}

/// Signature for the subprocess runner injected into [PrimarySelection].
///
/// Aliases [HostProcessRunner]. It returns a kit-owned [HostProcessResult]
/// rather than `dart:io`'s `ProcessResult`, because a `dart:io` type in this
/// public typedef made every consumer of the clipboard entrypoint
/// uncompilable for web.
typedef ProcessRunner = HostProcessRunner;

/// Result of a PATH probe for a CLI tool.
typedef _PathProbe = Future<bool> Function(String exe);

/// Accesses the Linux PRIMARY selection (highlight-to-copy, middle-click-to-paste).
///
/// Flutter's built-in [Clipboard] API covers only the CLIPBOARD selection
/// (Ctrl+C/V). This class fills the gap via subprocess calls to the standard
/// CLI tools available on the running session:
///
/// - **Wayland**: `wl-copy --primary` / `wl-paste --primary -n`
///   (from the `wl-clipboard` package).
/// - **X11 / XWayland**: `xclip -selection primary` (preferred) or
///   `xsel --primary` (fallback).
///
/// If no suitable tool is installed, [write] is a silent no-op and [read]
/// returns `null`.  The class never throws for a missing tool — only for
/// unexpected subprocess errors.
///
/// ### Dependency injection
///
/// Pass a [ProcessRunner] and/or [pathProbe] to replace real subprocess calls
/// in unit tests:
///
/// ```dart
/// final primary = PrimarySelection(
///   processRunner: fakeRunner,
///   pathProbe: (exe) async => exe == 'wl-copy',
/// );
/// ```
class PrimarySelection {
  /// Creates a [PrimarySelection] instance.
  ///
  /// [processRunner] is called for every subprocess invocation.
  /// [env] overrides the live [Platform.environment] for session detection.
  /// [pathProbe] checks whether a given executable is on PATH; defaults to
  /// calling `which <exe>`.
  PrimarySelection({
    ProcessRunner? processRunner,
    Map<String, String>? env,
    Future<bool> Function(String exe)? pathProbe,
  })  : _run = processRunner ?? runHostProcess,
        _session = detectLinuxSession(env: env),
        _pathProbe = pathProbe ?? hostExecutableExists;

  final ProcessRunner _run;
  final LinuxSession _session;
  final _PathProbe _pathProbe;

  // Cached tool availability.
  bool? _supported;
  String? _resolvedTool; // 'wl-copy', 'xclip', or 'xsel'

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns `true` when a suitable CLI tool is on PATH for the current session.
  ///
  /// The result is cached after the first call.
  Future<bool> get isSupported async {
    if (_supported != null) return _supported!;
    _supported = await _detectTool();
    return _supported!;
  }

  /// A human-readable hint about which package to install, or `null` when a
  /// tool is already available.
  ///
  /// Populated lazily (after the first [isSupported] / [write] / [read] call).
  String? get missingToolHint {
    if (_supported == null) return null; // not yet probed
    if (_supported!) return null; // tool is present
    return switch (_session) {
      LinuxSession.wayland =>
        'install wl-clipboard (e.g. apt install wl-clipboard)',
      LinuxSession.x11 ||
      LinuxSession.unknown =>
        'install xclip or xsel (e.g. apt install xclip)',
    };
  }

  /// Writes [text] to the PRIMARY selection.
  ///
  /// Silently no-ops when no suitable tool is installed.  Empty [text] is
  /// written as-is (clearing PRIMARY is a valid and common operation).
  Future<void> write(String text) async {
    if (!await isSupported) return;
    await _runWrite(text);
  }

  /// Reads the current PRIMARY selection, or `null` when unavailable.
  ///
  /// Returns `null` when no suitable tool is installed, when the subprocess
  /// exits non-zero, or when the selection is empty.
  Future<String?> read() async {
    if (!await isSupported) return null;
    return _runRead();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<bool> _detectTool() async {
    switch (_session) {
      case LinuxSession.wayland:
        if (await _pathProbe('wl-copy')) {
          _resolvedTool = 'wl-copy';
          return true;
        }
        return false;

      case LinuxSession.x11:
      case LinuxSession.unknown:
        if (await _pathProbe('xclip')) {
          _resolvedTool = 'xclip';
          return true;
        }
        if (await _pathProbe('xsel')) {
          _resolvedTool = 'xsel';
          return true;
        }
        return false;
    }
  }

  Future<void> _runWrite(String text) async {
    switch (_resolvedTool) {
      case 'wl-copy':
        await _run('wl-copy', ['--primary'], stdin: text);
      case 'xclip':
        await _run('xclip', ['-selection', 'primary'], stdin: text);
      case 'xsel':
        await _run('xsel', ['--primary', '--input'], stdin: text);
    }
  }

  Future<String?> _runRead() async {
    final HostProcessResult result;
    switch (_resolvedTool) {
      case 'wl-copy':
        result = await _run('wl-paste', ['--primary', '-n']);
      case 'xclip':
        result = await _run('xclip', ['-o', '-selection', 'primary']);
      case 'xsel':
        result = await _run('xsel', ['--primary', '--output']);
      default:
        return null;
    }
    if (!result.ok) return null;
    final String text = result.stdout.trim();
    return text.isEmpty ? null : text;
  }
}

// ---------------------------------------------------------------------------
// Widget helper
// ---------------------------------------------------------------------------

/// Wraps [child] in a [Listener] that calls [onMiddleClick] when the user
/// presses the middle mouse button (tertiary pointer button).
///
/// Uses [HitTestBehavior.translucent] so middle-clicks anywhere within the
/// widget's bounds fire — including over transparent or empty interiors —
/// while still passing events through to the child and any widget behind it.
///
/// ### How PRIMARY selection works end-to-end
///
/// 1. The app calls `primary.write(selectedText)` from its selection-changed
///    callback whenever the user highlights text.  This mimics what all native
///    Linux apps do automatically: any selected text is immediately available
///    on the PRIMARY selection.
///
/// 2. When the user middle-clicks, [onMiddleClick] fires.  Your handler
///    should call `primary.read()` and insert the result at the cursor.
///
/// ```dart
/// Widget build(BuildContext context) {
///   return middleClickPaste(
///     onMiddleClick: () async {
///       final text = await primary.read();
///       if (text != null) controller.insertText(text);
///     },
///     child: MyEditorWidget(),
///   );
/// }
/// ```
Widget middleClickPaste({
  required Widget child,
  required Future<void> Function() onMiddleClick,
}) {
  return Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (PointerDownEvent event) {
      // kMiddleMouseButton == 0x04 (bit 2) in Flutter's gesture constants.
      // kTertiaryButton is an alias for the same value.
      const int kMiddleMouseButton = 0x04;
      if (event.buttons & kMiddleMouseButton != 0) {
        onMiddleClick();
      }
    },
    child: child,
  );
}
