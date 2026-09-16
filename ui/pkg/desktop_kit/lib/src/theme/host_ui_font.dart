// Host UI-font autodetection. On GNOME the desktop interface font (e.g.
// "Cantarell 11") is exposed via gsettings; reading it lets an app adopt the
// host chrome font when the user hasn't picked an app font. Only the
// Process.run lives behind the OS boundary; [parseGnomeFontName] is pure and
// unit-testable. Ported from alert-log — the app-side Riverpod
// `hostUiFontProvider` is intentionally OMITTED so the core stays
// state-management agnostic; an app wires the result of [detectHostUiFont] into
// whatever provider/store it uses.
library;

import '../host/host_env_default.dart';
import '../host/host_process_default.dart';

/// Parse a GNOME `font-name` value into a bare family name, or null when it is
/// empty/blank. gsettings wraps the value in single quotes and appends a
/// point-size token, e.g. `'Cantarell 11'` → `Cantarell`, `'Cantarell Bold 11'`
/// → `Cantarell Bold`. A value with no trailing size is returned unchanged.
String? parseGnomeFontName(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  // Strip a matched pair of surrounding quotes (gsettings emits single quotes).
  if (s.length >= 2) {
    final first = s[0];
    final last = s[s.length - 1];
    if ((first == "'" && last == "'") || (first == '"' && last == '"')) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  if (s.isEmpty) return null;
  // Drop a trailing point-size token (integer or decimal): "Cantarell 11" → 11.
  final words = s.split(RegExp(r'\s+'));
  if (words.length >= 2 && RegExp(r'^\d+(\.\d+)?$').hasMatch(words.last)) {
    words.removeLast();
  }
  final result = words.join(' ').trim();
  return result.isEmpty ? null : result;
}

/// Detect the host UI font family, or null when it cannot be determined.
///
/// On Linux, reads `gsettings get org.gnome.desktop.interface font-name` and
/// parses the result with [parseGnomeFontName]. On every other platform — or
/// when gsettings is missing / errors / returns nothing — resolves to null.
///
/// On a browser host the Linux guard short-circuits before any subprocess is
/// attempted, so this resolves to null without throwing: an app simply keeps
/// its own font choice, which is the same outcome as a non-GNOME desktop.
///
/// This spawns a subprocess, so it should be run ONCE (e.g. from `main()`) and
/// its result fed into the app's own state — never watched lazily from the
/// widget tree (a live future would spawn the process inside widget tests and
/// leak its pending Timer past disposal).
Future<String?> detectHostUiFont() async {
  if (hostEnv.os != HostOs.linux) return null;
  try {
    final HostProcessResult result =
        await runHostProcess('gsettings', const <String>[
      'get',
      'org.gnome.desktop.interface',
      'font-name',
    ]);
    if (!result.ok) return null;
    return parseGnomeFontName(result.stdout);
  } catch (_) {
    return null;
  }
}
