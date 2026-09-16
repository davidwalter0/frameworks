// Widget tests for XiGlyph.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('XiGlyph', () {
    testWidgets('renders the ξ character', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: XiGlyph())),
        ),
      );
      expect(find.text('ξ'), findsOneWidget);
    });

    testWidgets('respects explicit size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: XiGlyph(size: 48))),
        ),
      );
      final textWidget = tester.widget<Text>(find.text('ξ'));
      expect(textWidget.style?.fontSize, 48.0);
    });

    testWidgets('respects explicit color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: XiGlyph(color: Colors.red)),
          ),
        ),
      );
      final textWidget = tester.widget<Text>(find.text('ξ'));
      expect(textWidget.style?.color, Colors.red);
    });

    testWidgets('defaults to IconTheme size when no explicit size',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: IconTheme(
              data: IconThemeData(size: 36),
              child: XiGlyph(),
            ),
          ),
        ),
      );
      final textWidget = tester.widget<Text>(find.text('ξ'));
      expect(textWidget.style?.fontSize, 36.0);
    });

    testWidgets('falls back to 24 when IconTheme has no size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: XiGlyph()),
        ),
      );
      final textWidget = tester.widget<Text>(find.text('ξ'));
      // Material's default IconTheme size is 24.
      expect(textWidget.style?.fontSize, 24.0);
    });
  });
}
