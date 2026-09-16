// Tests for readClipboard — the symmetric read for setClipboard.
//
// A fake platform clipboard backs SystemChannels.platform so set/getData
// round-trip in-memory: setClipboard stores the text, readClipboard returns
// it, and an empty/absent clipboard reports null.
library;

import 'package:desktop_kit/desktop_kit_clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake clipboard platform channel
// ---------------------------------------------------------------------------

/// In-memory fake of the platform clipboard: `Clipboard.setData` stores the
/// text and `Clipboard.getData` returns it, so set-then-read round-trips.
class _FakePlatformClipboard {
  String? stored;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            final Map<Object?, Object?> args =
                call.arguments as Map<Object?, Object?>;
            stored = args['text'] as String?;
            return null;
          case 'Clipboard.getData':
            // Flutter's Clipboard.getData casts response['text'] to String, so
            // an empty/absent clipboard must be signalled by a null *response*
            // (not a map with a null text field, which would throw on cast).
            final String? value = stored;
            if (value == null || value.isEmpty) return null;
            return <String, dynamic>{'text': value};
        }
        return null;
      },
    );
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }
}

void main() {
  // Mock platform channels require an initialised binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('readClipboard', () {
    late _FakePlatformClipboard fake;

    setUp(() {
      fake = _FakePlatformClipboard()..install();
    });

    tearDown(() => fake.uninstall());

    test('returns null when the clipboard is empty', () async {
      // Nothing written yet — stored is null.
      expect(await readClipboard(), isNull);
    });

    test('returns null when the clipboard holds an empty string', () async {
      fake.stored = '';
      expect(await readClipboard(), isNull);
    });

    test('set-then-read round-trips the text', () async {
      await setClipboard('round trip');
      expect(fake.stored, 'round trip');
      expect(await readClipboard(), 'round trip');
    });

    test('reflects the latest write', () async {
      await setClipboard('first');
      expect(await readClipboard(), 'first');
      await setClipboard('second');
      expect(await readClipboard(), 'second');
    });

    test('reads a value placed by another writer', () async {
      // Simulate another app putting text on the clipboard out-of-band.
      fake.stored = 'external value';
      expect(await readClipboard(), 'external value');
    });
  });
}
