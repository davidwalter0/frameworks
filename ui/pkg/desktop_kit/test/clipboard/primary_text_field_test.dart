import 'package:desktop_kit/desktop_kit_clipboard.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A PrimarySelection wired to a fake `xclip` on an x11 session: records the
  // text passed to write (via stdin) and returns [readValue] on read. No real
  // subprocess is ever spawned.
  PrimarySelection fakePrimary({List<String>? writes, String? readValue}) {
    return PrimarySelection(
      env: const {'DISPLAY': ':0'},
      pathProbe: (exe) async => exe == 'xclip',
      processRunner: (exe, args, {stdin}) async {
        if (stdin != null) {
          writes?.add(stdin);
          return const HostProcessResult(exitCode: 0, stdout: '', stderr: '');
        }
        return HostProcessResult(
            exitCode: 0, stdout: readValue ?? '', stderr: '');
      },
    );
  }

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('mirrors the highlighted selection into PRIMARY (debounced)',
      (tester) async {
    final writes = <String>[];
    final controller = TextEditingController(text: 'water 水');
    addTearDown(controller.dispose);

    await pump(
      tester,
      PrimaryTextField(
        controller: controller,
        primary: fakePrimary(writes: writes),
      ),
    );

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump(const Duration(milliseconds: 200)); // past 150ms debounce
    await tester.pumpAndSettle();

    expect(writes, ['water']);
  });

  testWidgets('middle-click pastes the PRIMARY selection at the caret',
      (tester) async {
    final controller = TextEditingController(text: 'ab');
    addTearDown(controller.dispose);

    await pump(
      tester,
      PrimaryTextField(
        controller: controller,
        primary: fakePrimary(readValue: 'X'),
      ),
    );

    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextField)),
      buttons: kMiddleMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    // 'X' was inserted (exact caret position is left to the field).
    expect(controller.text, contains('X'));
    expect(controller.text.length, 3);
  });

  testWidgets('enablePrimarySelection:false is a plain passthrough',
      (tester) async {
    final writes = <String>[];
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);

    await pump(
      tester,
      PrimaryTextField(
        controller: controller,
        primary: fakePrimary(writes: writes),
        enablePrimarySelection: false,
      ),
    );

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(writes, isEmpty); // no PRIMARY write when disabled
  });
}
