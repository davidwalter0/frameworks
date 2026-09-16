import 'package:desktop_kit/desktop_kit_clipboard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectLinuxSession', () {
    // Helper: builds a sparse env from key-value pairs.
    Map<String, String> env(List<(String, String)> pairs) =>
        Map.fromEntries(pairs.map((p) => MapEntry(p.$1, p.$2)));

    // -------------------------------------------------------------------------
    // Wayland cases
    // -------------------------------------------------------------------------

    test('wayland: XDG_SESSION_TYPE=wayland, no DISPLAY → wayland', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('XDG_SESSION_TYPE', 'wayland')]),
      );
      expect(result, LinuxSession.wayland);
    });

    test('wayland: XDG_SESSION_TYPE=wayland, DISPLAY empty → wayland', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('XDG_SESSION_TYPE', 'wayland'), ('DISPLAY', '')]),
      );
      expect(result, LinuxSession.wayland);
    });

    test(
        'wayland: WAYLAND_DISPLAY set, no XDG_SESSION_TYPE, no DISPLAY → wayland',
        () {
      final LinuxSession result = detectLinuxSession(
        env: env([('WAYLAND_DISPLAY', 'wayland-0')]),
      );
      expect(result, LinuxSession.wayland);
    });

    // -------------------------------------------------------------------------
    // XWayland case (the subtle one)
    // -------------------------------------------------------------------------

    test(
        'xwayland: XDG_SESSION_TYPE=wayland AND DISPLAY set → x11 '
        '(Flutter GTK embedder is an X11 client under XWayland)', () {
      final LinuxSession result = detectLinuxSession(
        env: env([
          ('XDG_SESSION_TYPE', 'wayland'),
          ('DISPLAY', ':1'),
          ('WAYLAND_DISPLAY', 'wayland-0'),
        ]),
      );
      expect(result, LinuxSession.x11);
    });

    // -------------------------------------------------------------------------
    // X11 cases
    // -------------------------------------------------------------------------

    test('x11: XDG_SESSION_TYPE=x11 → x11', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('XDG_SESSION_TYPE', 'x11')]),
      );
      expect(result, LinuxSession.x11);
    });

    test('x11: only DISPLAY set → x11', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('DISPLAY', ':0')]),
      );
      expect(result, LinuxSession.x11);
    });

    test('x11: XDG_SESSION_TYPE=x11 and DISPLAY set → x11', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('XDG_SESSION_TYPE', 'x11'), ('DISPLAY', ':0')]),
      );
      expect(result, LinuxSession.x11);
    });

    // -------------------------------------------------------------------------
    // Unknown cases
    // -------------------------------------------------------------------------

    test('unknown: empty environment → unknown', () {
      final LinuxSession result = detectLinuxSession(env: {});
      expect(result, LinuxSession.unknown);
    });

    test('unknown: unrecognised XDG_SESSION_TYPE, no DISPLAY → unknown', () {
      final LinuxSession result = detectLinuxSession(
        env: env([('XDG_SESSION_TYPE', 'mir')]),
      );
      expect(result, LinuxSession.unknown);
    });
  });
}
