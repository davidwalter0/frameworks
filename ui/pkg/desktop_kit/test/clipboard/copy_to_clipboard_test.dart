import 'package:desktop_kit/desktop_kit_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake clipboard platform channel
// ---------------------------------------------------------------------------

/// Records each value passed to [Clipboard.setData] via the platform channel.
class _FakePlatformClipboard {
  String? lastSetText;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          lastSetText = args['text'] as String?;
        }
        // Return an empty response so getData calls don't hang.
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': null};
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // setClipboard — pure unit tests (no widget pump needed)
  // -------------------------------------------------------------------------

  group('setClipboard', () {
    // Each group has its own late + setUp/tearDown to avoid cross-group
    // late-initialisation errors under the Dart runtime.
    late _FakePlatformClipboard fake;

    setUp(() {
      fake = _FakePlatformClipboard()..install();
    });

    // Use a lambda so `fake` is evaluated lazily at teardown time (not when
    // the tearDown call itself is registered, which would trigger a
    // LateInitializationError).
    tearDown(() => fake.uninstall());

    test('writes text to the platform clipboard', () async {
      await setClipboard('hello');
      expect(fake.lastSetText, 'hello');
    });

    test('no-ops on empty string', () async {
      await setClipboard('');
      expect(fake.lastSetText, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // copyToClipboard — widget tests
  // -------------------------------------------------------------------------

  group('copyToClipboard', () {
    late _FakePlatformClipboard fake;

    setUp(() {
      fake = _FakePlatformClipboard()..install();
    });

    tearDown(() => fake.uninstall());

    // Pumps a minimal app: a Scaffold wrapping a Builder so the inner
    // [BuildContext] has a [ScaffoldMessenger] in scope.
    Future<void> pumpApp(
      WidgetTester tester, {
      required Future<void> Function(BuildContext) onPressed,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => onPressed(context),
                child: const Text('Copy'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows SnackBar with label when label provided', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        onPressed: (ctx) => copyToClipboard(ctx, 'world', label: 'greeting'),
      );

      await tester.tap(find.text('Copy'));
      await tester.pump(); // kick off the async work
      await tester.pump(); // let SnackBar animate in

      expect(fake.lastSetText, 'world');
      expect(find.text('Copied greeting'), findsOneWidget);
    });

    testWidgets('shows SnackBar with char-count when no label provided', (
      WidgetTester tester,
    ) async {
      const String text = 'Hello, World!'; // 13 chars
      await pumpApp(
        tester,
        onPressed: (ctx) => copyToClipboard(ctx, text),
      );

      await tester.tap(find.text('Copy'));
      await tester.pump();
      await tester.pump();

      expect(fake.lastSetText, text);
      expect(find.text('Copied 13 chars'), findsOneWidget);
    });

    testWidgets(
        'still writes clipboard even when no ScaffoldMessenger in scope', (
      WidgetTester tester,
    ) async {
      // Pump a bare widget tree without a Scaffold — ScaffoldMessenger.maybeOf
      // returns null and no SnackBar is shown, but the clipboard write still
      // happens.
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => copyToClipboard(context, 'bare'),
              child: const Text('Copy'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Copy'));
      await tester.pump();
      await tester.pump();

      // Clipboard was written despite the missing ScaffoldMessenger.
      expect(fake.lastSetText, 'bare');
      // No exception thrown — test would fail otherwise.
    });
  });
}
