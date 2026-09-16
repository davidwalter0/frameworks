import 'package:desktop_kit/desktop_kit_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A child that owns state, so a remount is observable. No key: the point is
/// that a caller needs none.
class _StatefulChild extends StatefulWidget {
  const _StatefulChild();

  static int mounts = 0;

  @override
  State<_StatefulChild> createState() => _StatefulChildState();
}

class _StatefulChildState extends State<_StatefulChild> {
  @override
  void initState() {
    super.initState();
    _StatefulChild.mounts += 1;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  group('applyUiScale', () {
    testWidgets('scale == 1.0 leaves the ambient text scaler and icon size',
        (WidgetTester tester) async {
      // What the identity shortcut was really protecting: at the default
      // slider value the OS accessibility text factor must pass through
      // untouched (see docs/accessibility-signal-findings.org), and the
      // ambient icon size must be unchanged. Both now hold because the
      // wrapper is a no-op at 1.0, not because there is no wrapper.
      double? scaled;
      double? iconSize;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: MaterialApp(
            home: IconTheme(
              data: const IconThemeData(size: 20),
              child: Builder(
                builder: (BuildContext context) => applyUiScale(
                  context,
                  1.0,
                  Builder(
                    builder: (BuildContext inner) {
                      scaled = MediaQuery.textScalerOf(inner).scale(10);
                      iconSize = IconTheme.of(inner).size;
                      return const SizedBox();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(scaled, closeTo(12.5, 1e-9)); // 10 * the ambient 1.25, not 1.0
      expect(iconSize, closeTo(20.0, 1e-9)); // the ambient size, not 24
    });

    testWidgets('changing scale does not remount the child',
        (WidgetTester tester) async {
      // Same defect class as SpanHost's: returning the child BARE at 1.0 and
      // WRAPPED otherwise puts two structurally different widgets in one slot,
      // so Flutter disposes the subtree and inflates a fresh one. This helper
      // is documented to wrap MaterialApp.builder's child — the Navigator — so
      // the shortcut dropped the whole route stack, and every page's unsaved
      // state with it, when a user nudged the zoom slider.
      _StatefulChild.mounts = 0;
      Widget tree(double scale) => MaterialApp(
            home: Builder(
              builder: (BuildContext context) =>
                  applyUiScale(context, scale, const _StatefulChild()),
            ),
          );

      await tester.pumpWidget(tree(1.0));
      final _StatefulChildState original =
          tester.state<_StatefulChildState>(find.byType(_StatefulChild));

      for (final double scale in <double>[1.2, 1.0, 0.8, 1.0]) {
        await tester.pumpWidget(tree(scale));
        await tester.pump();
        expect(
          tester.state<_StatefulChildState>(find.byType(_StatefulChild)),
          same(original),
          reason: 'scale $scale remounted the child',
        );
      }
      expect(_StatefulChild.mounts, 1);
    });

    testWidgets(
        'scale != 1.0 scales the descendant text scaler (10 -> 12.5 at 1.25x)',
        (WidgetTester tester) async {
      double? scaled;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return applyUiScale(
                context,
                1.25,
                Builder(
                  builder: (BuildContext inner) {
                    scaled = MediaQuery.textScalerOf(inner).scale(10);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );

      expect(scaled, closeTo(12.5, 1e-9));
    });

    testWidgets('scale != 1.0 multiplies an already-set ambient icon size',
        (WidgetTester tester) async {
      double? iconSize;
      await tester.pumpWidget(
        MaterialApp(
          home: IconTheme(
            data: const IconThemeData(size: 20),
            child: Builder(
              builder: (BuildContext context) {
                return applyUiScale(
                  context,
                  1.25,
                  Builder(
                    builder: (BuildContext inner) {
                      iconSize = IconTheme.of(inner).size;
                      return const SizedBox();
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );

      expect(iconSize, closeTo(25.0, 1e-9)); // 20 ambient * 1.25
    });

    testWidgets('scale != 1.0 scales Material\'s 24.0 default icon size',
        (WidgetTester tester) async {
      double? iconSize;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return applyUiScale(
                context,
                1.25,
                Builder(
                  builder: (BuildContext inner) {
                    iconSize = IconTheme.of(inner).size;
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );

      expect(iconSize, closeTo(30.0, 1e-9)); // 24 default * 1.25
    });

    testWidgets('a non-default scale leaves an actual Icon visibly larger',
        (WidgetTester tester) async {
      const Widget icon = Icon(Icons.star);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) =>
                applyUiScale(context, 1.5, const Center(child: icon)),
          ),
        ),
      );

      final Size size = tester.getSize(find.byType(Icon));
      // 24.0 default * 1.5 == 36.0 in both dimensions.
      expect(size.width, closeTo(36.0, 0.5));
      expect(size.height, closeTo(36.0, 0.5));
    });
  });
}
