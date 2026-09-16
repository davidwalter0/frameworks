// Widget test for SavedIndicator: verifies it shows after savedAt changes.
library;

import 'package:desktop_kit/desktop_kit_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SavedIndicator', () {
    testWidgets('is invisible initially', (WidgetTester tester) async {
      final notifier = ValueNotifier<DateTime?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedIndicator(savedAt: notifier),
          ),
        ),
      );

      // Widget is present but opacity is 0 — label text is in the tree but
      // the AnimatedOpacity hides it.
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0.0);
    });

    testWidgets('becomes visible after savedAt emits a timestamp',
        (WidgetTester tester) async {
      final notifier = ValueNotifier<DateTime?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedIndicator(savedAt: notifier),
          ),
        ),
      );

      // Trigger a save notification.
      notifier.value = DateTime.now();
      await tester.pump(); // listener fires
      await tester.pump(const Duration(milliseconds: 1)); // animation tick

      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 1.0);

      // Label is present in the widget tree.
      expect(find.text('Saved ✓'), findsOneWidget);
    });

    testWidgets('fades out after holdDuration', (WidgetTester tester) async {
      final notifier = ValueNotifier<DateTime?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedIndicator(
              savedAt: notifier,
              holdDuration: const Duration(milliseconds: 100),
              fadeDuration: const Duration(milliseconds: 50),
            ),
          ),
        ),
      );

      notifier.value = DateTime.now();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      // Visible.
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
      );

      // Advance past holdDuration.
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.0,
      );
    });

    testWidgets('custom label is displayed', (WidgetTester tester) async {
      final notifier = ValueNotifier<DateTime?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavedIndicator(
              savedAt: notifier,
              label: 'Changes saved',
            ),
          ),
        ),
      );
      notifier.value = DateTime.now();
      await tester.pump();
      expect(find.text('Changes saved'), findsOneWidget);
    });
  });
}
