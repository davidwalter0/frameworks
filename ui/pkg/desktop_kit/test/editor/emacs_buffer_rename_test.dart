// rename-buffer: buffer identity is what the buffer list, C-x b and the mode
// line key on, so a host that loads files must be able to name them.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EmacsBuffer.renameBuffer', () {
    test('renames the current buffer', () {
      final EmacsBuffer b = EmacsBuffer(text: 'hello');
      expect(b.currentBuffer, '*scratch*');

      b.renameBuffer('README.md');

      expect(b.currentBuffer, 'README.md');
    });

    test('the renamed buffer keeps its text and caret', () {
      final EmacsBuffer b = EmacsBuffer(text: 'hello', caret: 2);
      b.renameBuffer('notes.org');

      expect(b.text, 'hello');
      expect(b.caret, 2);
    });

    test('the new name appears in the buffer list, the old one does not', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('*shell*');
      b.switchToBuffer('*scratch*');

      b.renameBuffer('README.md');
      // Force the entry to materialise the way any buffer switch would.
      b.newBuffer('*other*');

      expect(b.bufferNames, contains('README.md'));
      expect(b.bufferNames, isNot(contains('*scratch*')));
    });

    test('uniquifies on collision instead of clobbering', () {
      // Two files with the same basename in different directories is
      // ordinary — Emacs disambiguates rather than refusing.
      final EmacsBuffer b = EmacsBuffer(text: 'first');
      b.newBuffer('README.md');
      b.switchToBuffer('*scratch*');

      b.renameBuffer('README.md');

      expect(b.currentBuffer, 'README.md<2>');
      expect(b.bufferNames, contains('README.md'));
    });

    test('uniquifying keeps counting past the second collision', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('README.md');
      b.newBuffer('README.md<2>');
      b.switchToBuffer('*scratch*');

      b.renameBuffer('README.md');

      expect(b.currentBuffer, 'README.md<3>');
    });

    test('renaming to the current name is a no-op, not a self-collision', () {
      // Without the early return this would produce `*scratch*<2>`.
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.newBuffer('keep');
      b.switchToBuffer('*scratch*');

      b.renameBuffer('*scratch*');

      expect(b.currentBuffer, '*scratch*');
    });

    test('an empty or whitespace name is ignored', () {
      final EmacsBuffer b = EmacsBuffer(text: 'x');
      b.renameBuffer('   ');
      expect(b.currentBuffer, '*scratch*');
      b.renameBuffer('');
      expect(b.currentBuffer, '*scratch*');
    });
  });
}
