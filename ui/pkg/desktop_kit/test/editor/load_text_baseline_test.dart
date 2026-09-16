// Loading a file is not an edit, so it must not be undoable.
//
// `overwriteText` records undo. Loading a file into a fresh buffer therefore
// left exactly ONE undoable state — the empty buffer — so a single undo after
// opening a file blanked it. Worse, the redo stack is dropped as soon as
// anything else is typed, so the content could become unrecoverable from one
// keystroke on a file the user had merely opened.
//
// `loadText` establishes baseline content instead: text in, history cleared,
// modified false. This mirrors Emacs, where `find-file` leaves
// `buffer-undo-list` empty — you cannot undo your way to before a file existed
// in its buffer.
//
// The exposure used to end at the first buffer switch, because switchToBuffer
// discarded undo. Now that undo is buffer-local and persists, the stale
// snapshot survives indefinitely, which is what turned a narrow window into a
// standing hazard.
library;

import 'package:desktop_kit/src/editor/emacs_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('loadText establishes a baseline', () {
    test('undo right after a load does NOT blank the buffer', () {
      final EmacsBuffer b = EmacsBuffer(text: 'scratch');
      b.newBuffer('README.md');
      b.loadText('LINE1\nLINE2\nLINE3\n', caret: 0);

      expect(b.execute('undo'), isTrue, reason: 'the intent still resolves');
      expect(b.text, 'LINE1\nLINE2\nLINE3\n',
          reason: 'there is nothing to undo — loading a file is not an edit');
    });

    test('a load leaves the buffer unmodified', () {
      final EmacsBuffer b = EmacsBuffer(text: '');
      b.newBuffer('notes.org');
      b.loadText('* Heading\nbody\n');

      expect(b.bufferNamed('notes.org')!.modified, isFalse,
          reason: 'a freshly opened file is not dirty');
    });

    test('edits AFTER a load are still undoable, back to the loaded text', () {
      // The fix must not throw away real undo — only the load step.
      final EmacsBuffer b = EmacsBuffer(text: '');
      b.newBuffer('README.md');
      b.loadText('BASE\n', caret: 0);

      b.caret = 0;
      b.insert('EDIT-');
      expect(b.text, 'EDIT-BASE\n');
      expect(b.bufferNamed('README.md')!.modified, isTrue);

      b.execute('undo');
      expect(b.text, 'BASE\n',
          reason: 'undo returns to the loaded baseline, and stops there');

      b.execute('undo');
      expect(b.text, 'BASE\n',
          reason: 'a second undo cannot go behind the load');
    });

    test('the load history of one buffer does not leak into another', () {
      // Different lengths and line counts: a stale snapshot replayed into the
      // wrong buffer would produce plausible text, not an error.
      final EmacsBuffer b = EmacsBuffer(text: 'SCRATCH-ONE-LINE');
      final String scratch = b.currentBuffer;
      b.newBuffer('a.txt');
      b.loadText('a1\na2\na3\n', caret: 0);
      b.newBuffer('b.txt');
      b.loadText('b1\nb2\n', caret: 0);

      b.switchToBuffer('a.txt');
      b.execute('undo');
      expect(b.text, 'a1\na2\na3\n');

      b.switchToBuffer(scratch);
      expect(b.text, 'SCRATCH-ONE-LINE');
    });

    test('overwriteText REMAINS undo-recorded — revert must stay recoverable',
        () {
      // revert-buffer deliberately uses overwriteText so an accidental revert
      // is C-/-able. This pins that distinction so a later cleanup does not
      // "simplify" the two into one.
      final EmacsBuffer b = EmacsBuffer(text: '');
      b.newBuffer('README.md');
      b.loadText('LOADED\n', caret: 0);

      b.overwriteText('REVERTED\n');
      expect(b.text, 'REVERTED\n');

      b.execute('undo');
      expect(b.text, 'LOADED\n',
          reason: 'a revert is an edit and must be undoable');
    });
  });
}
