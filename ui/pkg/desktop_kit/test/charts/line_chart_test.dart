import 'package:desktop_kit/desktop_kit_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<ChartSeries> _threeSeries() {
  final CategoricalPalette palette = CategoricalPalette(kCategoricalLight);
  ChartSeries series(String name) => ChartSeries(
        name: name,
        color: palette.colorFor(name),
        points: <ChartPoint>[
          ChartPoint.time(DateTime(2026, 7, 18, 10), 1),
          ChartPoint.time(DateTime(2026, 7, 18, 11), 2),
        ],
      );
  return <ChartSeries>[series('ok'), series('ERR'), series('rejected')];
}

Widget _harness(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('LineChart (time axis)', () {
    testWidgets('shows the title and a legend chip per series', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          LineChart(
            title: 'Call rate by outcome',
            series: _threeSeries(),
            emptyMessage: 'no data',
          ),
        ),
      );

      expect(find.text('Call rate by outcome'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
      expect(find.text('ERR'), findsOneWidget);
      expect(find.text('rejected'), findsOneWidget);
    });

    testWidgets('renders the empty-state message when there is no data', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const LineChart(
            title: 'Rejected calls',
            series: <ChartSeries>[],
            emptyMessage: 'no data for mgk_tool_call_rejected_total yet',
          ),
        ),
      );

      expect(
        find.text('no data for mgk_tool_call_rejected_total yet'),
        findsOneWidget,
      );
      expect(find.byType(DataTable), findsNothing);
    });

    testWidgets(
      'a single series shows no legend (the title carries the name)',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          _harness(
            LineChart(
              title: 'Rejected calls',
              series: <ChartSeries>[
                ChartSeries(
                  name: 'rejected',
                  color: Colors.red,
                  points: <ChartPoint>[
                    ChartPoint.time(DateTime(2026, 7, 18), 1),
                  ],
                ),
              ],
              emptyMessage: 'no data',
            ),
          ),
        );
        expect(find.text('rejected'), findsNothing);
      },
    );

    testWidgets(
        'the table toggle swaps the chart for a data table with a '
        'column per series', (WidgetTester tester) async {
      await tester.pumpWidget(
        _harness(
          LineChart(
            title: 'Call rate by outcome',
            series: _threeSeries(),
            emptyMessage: 'no data',
          ),
        ),
      );

      expect(find.byType(DataTable), findsNothing);
      await tester.tap(find.byTooltip('Show table'));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('ok'), findsWidgets);
      expect(find.text('ERR'), findsWidgets);
      expect(find.text('rejected'), findsWidgets);

      await tester.tap(find.byTooltip('Show chart'));
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsNothing);
    });

    testWidgets(
      'toggling a series off in the legend does not repaint the survivors '
      '(their swatch colors are unchanged)',
      (WidgetTester tester) async {
        final List<ChartSeries> series = _threeSeries();
        final Color errColor = series[1].color;
        final Color rejectedColor = series[2].color;

        await tester.pumpWidget(
          _harness(
            LineChart(
              title: 'Call rate by outcome',
              series: series,
              emptyMessage: 'no data',
            ),
          ),
        );

        Color swatchColorFor(String name) {
          final Finder textFinder = find.text(name);
          final Finder rowFinder =
              find.ancestor(of: textFinder, matching: find.byType(Row)).first;
          final Container swatch = tester.widget<Container>(
            find
                .descendant(of: rowFinder, matching: find.byType(Container))
                .first,
          );
          return swatch.color!;
        }

        expect(swatchColorFor('ERR'), errColor);
        expect(swatchColorFor('rejected'), rejectedColor);

        await tester.tap(find.text('ok'));
        await tester.pumpAndSettle();

        expect(swatchColorFor('ERR'), errColor);
        expect(swatchColorFor('rejected'), rejectedColor);
      },
    );
  });

  group('LineChart legend overflow guard', () {
    testWidgets(
        'a long series name in a NARROW host does not overflow the legend '
        'row -- regression test for the Row(mainAxisSize:min) + unbounded '
        'Text combination that overflowed under a real long, experiment-'
        'prefixed cohort label inside a ~500px-wide panel',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: LineChart(
                series: <ChartSeries>[
                  ChartSeries(
                    name: 'constellation-trainer · seed 42 / executive-off',
                    color: Colors.blue,
                    points: <ChartPoint>[
                      ChartPoint.time(DateTime(2026, 7, 18, 10), 1),
                    ],
                  ),
                  ChartSeries(
                    name: 'validation-grid · seed 42 / executive-on',
                    color: Colors.orange,
                    points: <ChartPoint>[
                      ChartPoint.time(DateTime(2026, 7, 18, 10), 2),
                    ],
                  ),
                ],
                emptyMessage: 'no data',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('LineChart (ordinal axis)', () {
    testWidgets(
      'plots ChartPoint.ordinal points and shows ordinal ticks in the table',
      (WidgetTester tester) async {
        final ChartSeries series = ChartSeries(
          name: 'accuracy',
          color: Colors.blue,
          points: <ChartPoint>[
            ChartPoint.ordinal(1, 0.5),
            ChartPoint.ordinal(2, 0.6),
            ChartPoint.ordinal(3, 0.7),
          ],
        );

        await tester.pumpWidget(
          _harness(
            LineChart(
              title: 'Accuracy over generation',
              series: <ChartSeries>[series],
              emptyMessage: 'no data',
              xAxisKind: ChartXAxisKind.ordinal,
              valueFormatter: (double v) => v.toStringAsFixed(2),
            ),
          ),
        );

        expect(find.text('Accuracy over generation'), findsOneWidget);

        await tester.tap(find.byTooltip('Show table'));
        await tester.pumpAndSettle();
        // The ordinal x column header, and one row per generation (labeled
        // with the bare-generation-number default tooltip formatter).
        expect(find.text('X'), findsOneWidget);
        expect(find.text('gen 1'), findsOneWidget);
        expect(find.text('gen 2'), findsOneWidget);
        expect(find.text('gen 3'), findsOneWidget);
      },
    );

    testWidgets('an xLabelFormatter override wins over the ordinal default', (
      WidgetTester tester,
    ) async {
      final ChartSeries series = ChartSeries(
        name: 'accuracy',
        color: Colors.blue,
        points: <ChartPoint>[
          ChartPoint.ordinal(1, 0.5),
          ChartPoint.ordinal(2, 0.6),
        ],
      );

      await tester.pumpWidget(
        _harness(
          LineChart(
            series: <ChartSeries>[series],
            emptyMessage: 'no data',
            xAxisKind: ChartXAxisKind.ordinal,
            xLabelFormatter: (double x) => 'Generation ${x.round()}',
          ),
        ),
      );

      await tester.tap(find.byTooltip('Show table'));
      await tester.pumpAndSettle();
      expect(find.text('Generation 1'), findsOneWidget);
      expect(find.text('Generation 2'), findsOneWidget);
    });
  });
}
