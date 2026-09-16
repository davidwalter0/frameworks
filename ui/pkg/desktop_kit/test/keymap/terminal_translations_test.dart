// The historical tty control-code translations (C-i = HT, C-j = LF, C-m = CR)
// are registered intents and bound in the default Emacs keymap.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('newline and insertTab are registered intents', () {
    final reg = KeymapRegistry.defaults();
    expect(reg.contains('newline'), isTrue);
    expect(reg.contains('insertTab'), isTrue);
    expect(reg.intentFor('newline'), isA<NewlineIntent>());
    expect(reg.intentFor('insertTab'), isA<InsertTabIntent>());
    expect(reg.idFor(const NewlineIntent()), 'newline');
    expect(reg.idFor(const InsertTabIntent()), 'insertTab');
  });

  test('C-j and C-m map to newline, C-i to insertTab (default Emacs keymap)',
      () {
    final map = Keymaps.forMode(KeymapMode.emacs);
    expect(
      map[const SingleActivator(LogicalKeyboardKey.keyJ, control: true)],
      isA<NewlineIntent>(),
    );
    expect(
      map[const SingleActivator(LogicalKeyboardKey.keyM, control: true)],
      isA<NewlineIntent>(),
    );
    expect(
      map[const SingleActivator(LogicalKeyboardKey.keyI, control: true)],
      isA<InsertTabIntent>(),
    );
  });
}
