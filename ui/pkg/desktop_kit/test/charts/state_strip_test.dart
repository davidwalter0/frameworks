import 'package:desktop_kit/desktop_kit_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(Widget child) => MaterialApp(home: Scaffold(body: child));

List<ChartSeries> _rows() => <ChartSeries>[
      ChartSeries(
        name: 'host1',
        color: Colors.grey,
        points: <ChartPoint>[
          ChartPoint.time(DateTime(2026, 7, 18, 9), 1),
          ChartPoint.time(DateTime(2026, 7, 18, 10), 1),
        ],
      ),
      ChartSeries(
        name: 'host2',
        color: Colors.grey,
        points: <ChartPoint>[
          ChartPoint.time(DateTime(2026, 7, 18, 9), 1),
          ChartPoint.time(DateTime(2026, 7, 18, 10), 0),
        ],
      ),
    ];

void main() {
  group('StateStrip', () {
    testWidgets('shows the title, status legend, and one row per entry', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          StateStrip(
            title: 'Upstream health',
            rows: _rows(),
            emptyMessage: 'no data',
            okColor: Colors.green,
            warnColor: Colors.orange,
            dangerColor: Colors.red,
          ),
        ),
      );

      expect(find.text('Upstream health'), findsOneWidget);
      expect(find.text('Healthy'), findsOneWidget);
      expect(find.text('Degraded'), findsOneWidget);
      expect(find.text('Down'), findsOneWidget);
      expect(find.text('host1'), findsOneWidget);
      expect(find.text('host2'), findsOneWidget);
    });

    testWidgets('renders the empty-state message when there are no rows', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const StateStrip(
            title: 'Upstream health',
            rows: <ChartSeries>[],
            emptyMessage: 'no data for mgk_upstream_health yet',
            okColor: Colors.green,
            warnColor: Colors.orange,
            dangerColor: Colors.red,
          ),
        ),
      );
      expect(find.text('no data for mgk_upstream_health yet'), findsOneWidget);
    });

    testWidgets('the table toggle lists each row, state, and as-of time', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          StateStrip(
            title: 'Upstream health',
            rows: _rows(),
            emptyMessage: 'no data',
            okColor: Colors.green,
            warnColor: Colors.orange,
            dangerColor: Colors.red,
          ),
        ),
      );

      await tester.tap(find.byTooltip('Show table'));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('host1'), findsOneWidget);
      expect(find.text('host2'), findsOneWidget);
      // host1's last sample is 1 (healthy); host2's last sample is 0 (down).
      expect(find.text('Healthy'), findsWidgets);
      expect(find.text('Down'), findsWidgets);
    });
  });

  group('HealthState.of', () {
    test('classifies >=1 healthy, <=0 down, else degraded', () {
      expect(HealthState.of(1), HealthState.healthy);
      expect(HealthState.of(1.5), HealthState.healthy);
      expect(HealthState.of(0), HealthState.down);
      expect(HealthState.of(-1), HealthState.down);
      expect(HealthState.of(0.5), HealthState.degraded);
    });
  });
}
