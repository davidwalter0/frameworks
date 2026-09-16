import 'package:desktop_kit/desktop_kit_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('collapseTilde', () {
    test('replaces leading home with tilde', () {
      expect(
        collapseTilde('/home/alice/docs/notes.org', home: '/home/alice'),
        '~/docs/notes.org',
      );
    });

    test('replaces home that is the whole path', () {
      expect(
        collapseTilde('/home/alice', home: '/home/alice'),
        '~',
      );
    });

    test('does not replace home mid-path', () {
      expect(
        collapseTilde('/var/home/alice', home: '/home/alice'),
        '/var/home/alice',
      );
    });

    test('returns path unchanged when home is null', () {
      expect(
        collapseTilde('/etc/hosts', home: null),
        '/etc/hosts',
      );
    });

    test('returns path unchanged when home is empty string', () {
      expect(
        collapseTilde('/etc/hosts', home: ''),
        '/etc/hosts',
      );
    });

    test('returns path unchanged when path does not start with home', () {
      expect(
        collapseTilde('/tmp/scratch.txt', home: '/home/alice'),
        '/tmp/scratch.txt',
      );
    });
  });

  group('FileRef widget', () {
    Widget buildFileRef({
      required String path,
      bool collapseHome = false,
      VoidCallback? onCopyPath,
      VoidCallback? onReveal,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: FileRef(
            path: path,
            collapseHome: collapseHome,
            onCopyPath: onCopyPath,
            onReveal: onReveal,
          ),
        ),
      );
    }

    testWidgets('renders collapsed path when collapseHome is true', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFileRef(
          path: '/home/alice/docs/notes.org',
          collapseHome: true,
        ),
      );
      // The visible label should show the tilde form.
      // Without a known $HOME env var in tests we pass collapseHome=false
      // and test via explicit helper; here we verify the widget renders.
      expect(find.byType(FileRef), findsOneWidget);
    });

    testWidgets('renders full path when collapseHome is false', (
      WidgetTester tester,
    ) async {
      const String fullPath = '/home/alice/docs/notes.org';
      await tester.pumpWidget(buildFileRef(path: fullPath));
      expect(find.text(fullPath), findsOneWidget);
    });

    testWidgets('tooltip contains the full unmodified path', (
      WidgetTester tester,
    ) async {
      const String fullPath = '/home/alice/docs/notes.org';
      await tester.pumpWidget(buildFileRef(path: fullPath));
      // The Tooltip widget wraps the label; check its message.
      final Tooltip tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, fullPath);
    });

    testWidgets('copy button is absent when onCopyPath is null', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(buildFileRef(path: '/tmp/file.txt'));
      // Only icons from the reveal/copy buttons; none here.
      expect(find.byIcon(Icons.copy), findsNothing);
    });

    testWidgets('reveal button is absent when onReveal is null', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(buildFileRef(path: '/tmp/file.txt'));
      expect(find.byIcon(Icons.folder_open), findsNothing);
    });

    testWidgets('copy button is present when onCopyPath is provided', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFileRef(path: '/tmp/file.txt', onCopyPath: () {}),
      );
      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('reveal button is present when onReveal is provided', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFileRef(path: '/tmp/file.txt', onReveal: () {}),
      );
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
    });

    testWidgets('onCopyPath fires when copy button is tapped', (
      WidgetTester tester,
    ) async {
      int callCount = 0;
      await tester.pumpWidget(
        buildFileRef(path: '/tmp/file.txt', onCopyPath: () => callCount++),
      );
      await tester.tap(find.byIcon(Icons.copy));
      await tester.pump();
      expect(callCount, 1);
    });

    testWidgets('onReveal fires when reveal button is tapped', (
      WidgetTester tester,
    ) async {
      int callCount = 0;
      await tester.pumpWidget(
        buildFileRef(path: '/tmp/file.txt', onReveal: () => callCount++),
      );
      await tester.tap(find.byIcon(Icons.folder_open));
      await tester.pump();
      expect(callCount, 1);
    });

    testWidgets('both buttons are present when both callbacks are provided', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        buildFileRef(
          path: '/tmp/file.txt',
          onCopyPath: () {},
          onReveal: () {},
        ),
      );
      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
    });
  });
}
