// Widget tests for showDesktopKitAbout: dialog opens, shows required content.
library;

import 'package:desktop_kit/desktop_kit_about.dart';
import 'package:desktop_kit/desktop_kit_version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('showDesktopKitAbout', () {
    testWidgets('dialog shows appName', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('TestApp'), findsWidgets);
    });

    testWidgets('dialog shows VersionInfo.displayString',
        (WidgetTester tester) async {
      const info = VersionInfo(
        version: '1.2.3',
        commit: 'abc1234',
        date: '2024-01-15',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                  version: info,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1.2.3'), findsWidgets);
    });

    testWidgets('dialog shows section title', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                  sections: const <AboutSection>[
                    AboutSection(
                      title: 'Credits',
                      body: 'Built by the team.',
                    ),
                  ],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Credits'), findsOneWidget);
      expect(find.text('Built by the team.'), findsOneWidget);
    });

    testWidgets('Close button dismisses the dialog',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('TestApp'), findsWidgets);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      // Dialog is gone — only the scaffold text remains, not the dialog title.
      expect(find.text('Open source licenses'), findsNothing);
    });

    testWidgets('tagline is shown when provided', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                  tagline: 'The best app ever',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('The best app ever'), findsOneWidget);
    });

    testWidgets('serviceVersion future is displayed when resolved',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                  serviceVersion: Future<String>.value('v2.0 (daemon)'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pump(); // open dialog
      await tester.pump(); // FutureBuilder resolves

      expect(find.text('v2.0 (daemon)'), findsOneWidget);
    });

    testWidgets('section linkUrl is shown as selectable text',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                  sections: const <AboutSection>[
                    AboutSection(
                      title: 'Homepage',
                      body: 'See project page.',
                      linkUrl: 'https://example.com',
                    ),
                  ],
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('https://example.com'), findsOneWidget);
    });

    testWidgets('Open source licenses button is present',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showDesktopKitAbout(
                  ctx,
                  appName: 'TestApp',
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Open source licenses'), findsOneWidget);
    });
  });
}
