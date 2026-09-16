// Tests for LedIndicator: color mapping, pulse gating (off/gray never pulse;
// reduced motion disables), sizes, semantics, high-contrast border.

import 'package:desktop_kit/desktop_kit_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(
    Widget child, {
    bool disableAnimations = false,
    bool highContrast = false,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: disableAnimations,
          highContrast: highContrast,
        ),
        child: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Container dotOf(WidgetTester tester) => tester.widget<Container>(
        find.descendant(
          of: find.byType(LedIndicator),
          matching: find.byType(Container),
        ),
      );

  test('status colors match the Angular LEDStatus palette', () {
    expect(LedStatus.red.color, const Color(0xFFF44336));
    expect(LedStatus.orange.color, const Color(0xFFFF9800));
    expect(LedStatus.green.color, const Color(0xFF4CAF50));
    expect(LedStatus.blue.color, const Color(0xFF2196F3));
    expect(LedStatus.gray.color, const Color(0xFFBDBDBD));
  });

  test('named sizes match the Angular component', () {
    expect(kLedSmall, 8);
    expect(kLedMedium, 12);
    expect(kLedLarge, 16);
  });

  testWidgets('renders colored dot at requested size', (tester) async {
    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.red, size: kLedLarge),
    ));
    final BoxDecoration deco = dotOf(tester).decoration! as BoxDecoration;
    expect(deco.color, LedStatus.red.color);
    expect(
      tester.getSize(find.byType(LedIndicator)).width,
      kLedLarge,
    );
  });

  testWidgets('pulse animates an active status', (tester) async {
    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.red, pulse: true),
    ));
    expect(find.byType(AnimatedBuilder), findsWidgets);
    // Let the animation run a bit, then dispose cleanly.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });

  testWidgets('off and gray never pulse', (tester) async {
    for (final LedStatus s in <LedStatus>[LedStatus.off, LedStatus.gray]) {
      await tester.pumpWidget(host(
        LedIndicator(status: s, pulse: true),
      ));
      expect(
        find.descendant(
          of: find.byType(LedIndicator),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
        reason: '$s must not pulse',
      );
    }
  });

  testWidgets('reduced motion disables pulse', (tester) async {
    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.red, pulse: true),
      disableAnimations: true,
    ));
    expect(
      find.descendant(
        of: find.byType(LedIndicator),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
  });

  testWidgets('high contrast adds a border', (tester) async {
    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.blue),
      highContrast: true,
    ));
    final BoxDecoration deco = dotOf(tester).decoration! as BoxDecoration;
    expect(deco.border, isNotNull);
  });

  testWidgets('semantics label present (default and override)', (tester) async {
    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.red),
    ));
    expect(find.bySemanticsLabel('Urgent indicator'), findsOneWidget);

    await tester.pumpWidget(host(
      const LedIndicator(status: LedStatus.red, semanticLabel: 'custom'),
    ));
    expect(find.bySemanticsLabel('custom'), findsOneWidget);
  });

  // Regression: _syncController disposes the controller when the pulse stops
  // and creates a NEW one when it restarts, so a single State creates several
  // tickers over its lifetime. Under SingleTickerProviderStateMixin the second
  // one asserted ("multiple tickers were created"), which any consumer that
  // toggles `pulse` on a mounted indicator hits — e.g. pulsing only while a
  // connection is degraded. The failure surfaced confusingly: the build threw,
  // Flutter substituted an ErrorWidget, and its huge intrinsic size blew out
  // the enclosing Row as a ~99k-pixel overflow that read as a layout bug.
  testWidgets('pulse can be toggled repeatedly on a mounted indicator',
      (tester) async {
    for (int i = 0; i < 3; i++) {
      await tester.pumpWidget(host(
        const LedIndicator(status: LedStatus.red, pulse: true),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: 'pulse on, round $i');

      await tester.pumpWidget(host(
        const LedIndicator(status: LedStatus.green),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull, reason: 'pulse off, round $i');
    }
  });
}
