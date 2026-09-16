import 'package:desktop_kit/desktop_kit_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CategoricalPalette', () {
    test('assigns colors in fixed slot order, first-seen', () {
      final CategoricalPalette p = CategoricalPalette(kCategoricalLight);
      expect(p.colorFor('ok'), kCategoricalLight[0]);
      expect(p.colorFor('ERR'), kCategoricalLight[1]);
      expect(p.colorFor('rejected'), kCategoricalLight[2]);
    });

    test('re-asking for the same entity returns the same color', () {
      final CategoricalPalette p = CategoricalPalette(kCategoricalLight);
      final Color first = p.colorFor('ok');
      expect(p.colorFor('ERR'), isNot(first));
      expect(p.colorFor('ok'), first);
    });

    test(
      'a filter that removes a series does not repaint the survivors '
      '(color follows the entity, not its rank)',
      () {
        final CategoricalPalette p = CategoricalPalette(kCategoricalLight);
        final Color ok = p.colorFor('ok');
        final Color err = p.colorFor('ERR');
        final Color rejected = p.colorFor('rejected');
        expect(ok, kCategoricalLight[0]);

        // "ok" is now hidden; only ERR/rejected are asked for again, as a
        // filtered render would do -- same instance, so the cache answers.
        expect(p.colorFor('ERR'), err);
        expect(p.colorFor('rejected'), rejected);
      },
    );

    test('a 5th+ distinct entity folds onto the last slot, never cycles', () {
      final CategoricalPalette p = CategoricalPalette(kCategoricalLight);
      for (int i = 0; i < kCategoricalLight.length; i++) {
        p.colorFor('e$i');
      }
      final Color fifth = p.colorFor('e4');
      final Color sixth = p.colorFor('e5');
      expect(fifth, kCategoricalLight.last);
      expect(sixth, kCategoricalLight.last);
      // Never silently reuses slot 0 for a later distinct entity.
      expect(fifth, isNot(kCategoricalLight[0]));
    });
  });

  group('categoricalPaletteFor', () {
    testWidgets('resolves to the light set under a light theme', (
      WidgetTester tester,
    ) async {
      late List<Color> resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: Builder(
            builder: (BuildContext context) {
              resolved = categoricalPaletteFor(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved, kCategoricalLight);
    });

    testWidgets('resolves to the dark set under a dark theme', (
      WidgetTester tester,
    ) async {
      late List<Color> resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (BuildContext context) {
              resolved = categoricalPaletteFor(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(resolved, kCategoricalDark);
    });
  });
}
