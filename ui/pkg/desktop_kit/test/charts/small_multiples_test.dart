import 'package:desktop_kit/desktop_kit_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(Widget child, {Size size = const Size(800, 600)}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: size.width, height: size.height, child: child),
    ),
  );
}

List<SmallMultipleFacet> _facets(int n) => <SmallMultipleFacet>[
      for (int i = 0; i < n; i++)
        SmallMultipleFacet(
          title: 'seed $i',
          child: SizedBox(
            key: ValueKey<String>('facet-content-$i'),
            height: 80,
            child: Text('content $i'),
          ),
        ),
    ];

void main() {
  group('SmallMultiples', () {
    testWidgets('800x600: renders one titled card per facet', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _harness(
          SmallMultiples(facets: _facets(3), emptyMessage: 'no facets'),
        ),
      );

      expect(find.text('seed 0'), findsOneWidget);
      expect(find.text('seed 1'), findsOneWidget);
      expect(find.text('seed 2'), findsOneWidget);
      expect(find.text('content 0'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('renders the empty-state message when there are no facets', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const SmallMultiples(
            facets: <SmallMultipleFacet>[],
            emptyMessage: 'no generation series available',
          ),
        ),
      );
      expect(find.text('no generation series available'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
    });

    testWidgets(
      'a wide window places two facets side by side (same row)',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _harness(
            SmallMultiples(
              facets: _facets(2),
              emptyMessage: 'no facets',
              minFacetWidth: 320,
            ),
            size: const Size(1400, 900),
          ),
        );

        final double topA = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 0')))
            .dy;
        final double topB = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 1')))
            .dy;
        final double leftA = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 0')))
            .dx;
        final double leftB = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 1')))
            .dx;
        expect(topA, topB, reason: 'same row -- equal top offsets');
        expect(leftB, greaterThan(leftA),
            reason: 'second column, to the right');
      },
    );

    testWidgets(
      'a narrow window (< 2x minFacetWidth) stacks facets to one column',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _harness(
            SmallMultiples(
              facets: _facets(2),
              emptyMessage: 'no facets',
              minFacetWidth: 320,
            ),
            size: const Size(400, 900),
          ),
        );

        final double topA = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 0')))
            .dy;
        final double topB = tester
            .getTopLeft(find.byKey(const ValueKey<String>('facet-seed 1')))
            .dy;
        expect(topB, greaterThan(topA),
            reason: 'stacked -- second below first');
      },
    );
  });
}
