import 'dart:async';

import 'package:desktop_kit/desktop_kit_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Foldable', () {
    Widget buildFoldable({
      required bool expanded,
      required VoidCallback onToggle,
      Widget? child,
      Future<void> Function()? onExpand,
      String? tooltip,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Foldable(
            expanded: expanded,
            onToggle: onToggle,
            header: const Text('Section'),
            child: child,
            tooltip: tooltip,
            onExpand: onExpand,
          ),
        ),
      );
    }

    testWidgets('shows chevron_right icon when collapsed', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFoldable(expanded: false, onToggle: () {}),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('shows expand_more icon when expanded', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFoldable(expanded: true, onToggle: () {}),
      );
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('fires onToggle when header is tapped', (
      WidgetTester tester,
    ) async {
      int callCount = 0;
      await tester.pumpWidget(
        buildFoldable(expanded: false, onToggle: () => callCount++),
      );
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(callCount, 1);
    });

    testWidgets('child is visible when expanded', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildFoldable(
          expanded: true,
          onToggle: () {},
          child: const Text('Body content'),
        ),
      );
      expect(find.text('Body content'), findsOneWidget);
    });

    testWidgets('child is hidden when collapsed', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildFoldable(
          expanded: false,
          onToggle: () {},
          child: const Text('Body content'),
        ),
      );
      expect(find.text('Body content'), findsNothing);
    });

    testWidgets('shows spinner while onExpand future is pending', (
      WidgetTester tester,
    ) async {
      // A completer we control so we can hold the future open.
      final Completer<void> completer = Completer<void>();

      await tester.pumpWidget(
        buildFoldable(
          expanded: false,
          onToggle: () {},
          onExpand: () => completer.future,
        ),
      );

      // Before tap: chevron visible, no spinner.
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Tap to start the expand.
      await tester.tap(find.byType(InkWell));
      await tester.pump(); // start the async operation

      // While future is pending: spinner visible, no chevron.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);

      // Complete the future.
      completer.complete();
      await tester.pumpAndSettle();

      // After completion: spinner gone, loading done.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('onToggle fires after onExpand future completes', (
      WidgetTester tester,
    ) async {
      final Completer<void> completer = Completer<void>();
      int callCount = 0;

      await tester.pumpWidget(
        buildFoldable(
          expanded: false,
          onToggle: () => callCount++,
          onExpand: () => completer.future,
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Not called yet — future still pending.
      expect(callCount, 0);

      completer.complete();
      await tester.pumpAndSettle();

      // Now called.
      expect(callCount, 1);
    });

    testWidgets('onExpand is NOT called when already expanded', (
      WidgetTester tester,
    ) async {
      int expandCount = 0;
      int toggleCount = 0;

      await tester.pumpWidget(
        buildFoldable(
          expanded: true,
          onToggle: () => toggleCount++,
          onExpand: () async => expandCount++,
        ),
      );

      await tester.tap(find.byType(InkWell));
      await tester.pump();

      // Collapsing — onExpand must not be called.
      expect(expandCount, 0);
      expect(toggleCount, 1);
    });

    testWidgets('renders tooltip wrapper when tooltip is provided', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFoldable(
          expanded: false,
          onToggle: () {},
          tooltip: 'Hover hint',
        ),
      );
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Hover hint');
    });
  });

  group('ExpandCollapseAllBar', () {
    Widget buildBar({
      required VoidCallback onExpandAll,
      required VoidCallback onCollapseAll,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: ExpandCollapseAllBar(
            onExpandAll: onExpandAll,
            onCollapseAll: onCollapseAll,
          ),
        ),
      );
    }

    testWidgets('renders expand-all and collapse-all buttons', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildBar(onExpandAll: () {}, onCollapseAll: () {}),
      );
      expect(find.byIcon(Icons.unfold_more), findsOneWidget);
      expect(find.byIcon(Icons.unfold_less), findsOneWidget);
    });

    testWidgets('fires onExpandAll when expand button is tapped', (
      WidgetTester tester,
    ) async {
      int callCount = 0;
      await tester.pumpWidget(
        buildBar(onExpandAll: () => callCount++, onCollapseAll: () {}),
      );
      await tester.tap(find.byIcon(Icons.unfold_more));
      await tester.pump();
      expect(callCount, 1);
    });

    testWidgets('fires onCollapseAll when collapse button is tapped', (
      WidgetTester tester,
    ) async {
      int callCount = 0;
      await tester.pumpWidget(
        buildBar(onExpandAll: () {}, onCollapseAll: () => callCount++),
      );
      await tester.tap(find.byIcon(Icons.unfold_less));
      await tester.pump();
      expect(callCount, 1);
    });
  });
}
