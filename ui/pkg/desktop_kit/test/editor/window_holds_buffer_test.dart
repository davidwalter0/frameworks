// Phase 8 — a WINDOW holds a Buffer OBJECT, and the model's selection is a
// Buffer REFERENCE with the NAME derived from it.
//
// Before this phase `EmacsBuffer` stored `String _currentBuffer` and derived
// `current` by map lookup, and `WindowLeaf` stored `String bufferName`. Both
// are keys into an index, and a key expires: `renameBuffer` re-keys the index,
// so every stored copy of the old name had to be found and fixed, and the one
// nobody remembered was the window's. Inverting it — the object is the truth,
// the name is derived — makes a rename a non-event for every holder.
//
// Fixtures deliberately differ in LENGTH and LINE COUNT. Equal-shaped buffers
// let an offset computed against one text and applied to another render
// plausibly, which is the failure mode this whole refactor exists to remove.
library;

import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// A model with `*scratch*` (1 line, 16 chars) and `notes` (4 lines, 35
/// chars), current = `*scratch*`.
EmacsBuffer _uneven() {
  final EmacsBuffer model = EmacsBuffer(text: 'SCRATCH-ONE-LINE');
  model.newBuffer('notes');
  model.insert('NOTES-L1\nNOTES-L2\nNOTES-L3\nNOTES-L4');
  model.switchToBuffer('*scratch*');
  return model;
}

void main() {
  group('the selection is a Buffer reference, the name is derived', () {
    test('a rename keeps the same object selected and updates the name', () {
      final EmacsBuffer model = EmacsBuffer(text: 'ONE\nTWO');
      final Buffer scratch = model.current;

      model.renameBuffer('renamed.org');

      expect(identical(model.current, scratch), isTrue,
          reason: 'rename must not change WHICH object is selected');
      expect(model.currentBuffer, 'renamed.org',
          reason: 'currentBuffer is derived from current.name');
      expect(scratch.name, 'renamed.org',
          reason: 'the buffer owns its name; the index merely keys on it');
      expect(model.bufferNamed('renamed.org'), same(scratch));
      expect(model.bufferNamed('*scratch*'), isNull);
    });

    test('the buffer list reports the selection by identity, not by name', () {
      // `bufferSnapshots` used to flag the current row with `e.key ==
      // _currentBuffer`. With the name derived that comparison is still
      // correct, but identity says what is actually meant and cannot be
      // fooled by a stale key.
      final EmacsBuffer model = _uneven();
      model.renameBuffer('scratch.org');

      final List<({String name, bool current, int lineCount, int byteCount})>
          rows = model.bufferSnapshots();
      expect(rows.where((r) => r.current).map((r) => r.name), <String>[
        'scratch.org',
      ]);
      // Different line counts prove the rows describe different buffers.
      final int notesLines =
          rows.firstWhere((r) => r.name == 'notes').lineCount;
      final int scratchLines =
          rows.firstWhere((r) => r.name == 'scratch.org').lineCount;
      expect(notesLines, 4);
      expect(scratchLines, 1);
    });
  });

  group('isLive — identity, not name equality', () {
    test('a renamed buffer is still live', () {
      final EmacsBuffer model = _uneven();
      final Buffer scratch = model.current;
      model.renameBuffer('scratch.org');
      expect(model.isLive(scratch), isTrue);
    });

    test('a killed buffer is not live', () {
      final EmacsBuffer model = _uneven();
      final Buffer notes = model.bufferNamed('notes')!;
      expect(model.isLive(notes), isTrue);

      model.killBufferNamed('notes');

      expect(model.isLive(notes), isFalse);
    });

    test('a NEW buffer reusing a killed name does not resurrect the old one',
        () {
      // The case a name-keyed liveness check gets exactly wrong: it would
      // report the stranded window as healthy and silently re-attach it to an
      // unrelated buffer that merely inherited the name.
      final EmacsBuffer model = _uneven();
      final Buffer notes = model.bufferNamed('notes')!;
      model.killBufferNamed('notes');

      model.newBuffer('notes');
      final Buffer newNotes = model.bufferNamed('notes')!;

      expect(identical(newNotes, notes), isFalse);
      expect(model.isLive(notes), isFalse,
          reason: 'the killed object stays dead even though its name is back');
      expect(model.isLive(newNotes), isTrue);
    });
  });

  group('WindowLeaf holds the Buffer object', () {
    test('a window survives a rename of the buffer it shows', () {
      final EmacsBuffer model = EmacsBuffer(text: 'ONE\nTWO\nTHREE');
      final Buffer shown = model.current;
      final WindowTree tree = WindowTree.single(shown);

      model.renameBuffer('notes.org');

      expect(identical(tree.focusedLeaf!.buffer, shown), isTrue);
      expect(tree.focusedLeaf!.bufferName, 'notes.org',
          reason: "the window's name is derived, so it followed the rename");
      expect(model.isLive(tree.focusedLeaf!.buffer), isTrue);
    });

    test('splitting clones the buffer the window actually holds', () {
      final EmacsBuffer model = _uneven();
      final Buffer notes = model.bufferNamed('notes')!;
      final WindowTree tree = WindowTree.single(notes).splitRight();

      expect(tree.leaves(), hasLength(2));
      expect(
        tree.leaves().every((WindowLeaf l) => identical(l.buffer, notes)),
        isTrue,
        reason: 'C-x 3 gives two windows on the SAME buffer',
      );
    });

    test('C-x 1 keeps the focused window on its own buffer', () {
      final EmacsBuffer model = _uneven();
      final Buffer notes = model.bufferNamed('notes')!;
      final WindowTree split = WindowTree.single(notes).splitBelow();
      split.leaves()[1].buffer = model.current; // other window shows *scratch*

      final WindowTree only = split.only();

      expect(only.leaves(), hasLength(1));
      expect(identical(only.leaves().single.buffer, notes), isTrue);
    });
  });

  group('current is driven by the selected window', () {
    test('selectBuffer makes the window the source of the selection', () {
      final EmacsBuffer model = _uneven();
      final Buffer notes = model.bufferNamed('notes')!;

      final WindowTree tree = WindowTree.single(model.current).splitRight();
      tree.leaves()[1].buffer = notes;
      final WindowTree moved = tree.cycleFocus();

      model.selectBuffer(moved.focusedLeaf!.buffer);

      expect(identical(model.current, notes), isTrue);
      expect(model.currentBuffer, 'notes');
      expect(model.text, 'NOTES-L1\nNOTES-L2\nNOTES-L3\nNOTES-L4');
    });

    test('selectBuffer on the already-selected buffer is a no-op', () {
      final EmacsBuffer model = _uneven();
      model.status = '';
      model.selectBuffer(model.current);
      expect(model.status, '',
          reason: 'no switch happened, so no status was written');
    });

    test('onSelectionChanged repoints the selected window on every switch', () {
      // The direction that used to be deferred to the next `C-x o`: a `C-x b`
      // moved the model and left the window's pointer stale. Anything reading
      // that pointer in between — a split, a C-x 1 — used the OLD buffer.
      final EmacsBuffer model = _uneven();
      WindowTree tree = WindowTree.single(model.current);
      model.onSelectionChanged = (Buffer b) => tree.focusedLeaf?.buffer = b;

      model.switchToBuffer('notes');

      expect(tree.focusedLeaf!.bufferName, 'notes');
      expect(identical(tree.focusedLeaf!.buffer, model.current), isTrue);

      tree = tree.splitRight();
      expect(
        tree
            .leaves()
            .every((WindowLeaf l) => identical(l.buffer, model.current)),
        isTrue,
        reason: 'the split cloned the buffer the window really shows',
      );
    });

    test('onSelectionChanged fires for newBuffer and for a kill-driven switch',
        () {
      final EmacsBuffer model = _uneven();
      final List<String> seen = <String>[];
      model.onSelectionChanged = (Buffer b) => seen.add(b.name);

      model.newBuffer('third');
      expect(seen, <String>['third'],
          reason: 'creating a buffer selects it, so a window must follow');

      // Killing the selected buffer switches to another one — the window has
      // to follow that too, or it is left holding a killed buffer.
      model.killBufferNamed('third');
      expect(seen, hasLength(2));
      expect(seen.last, isNot('third'));
      expect(model.currentBuffer, seen.last);
    });

    test('a switch that does not move the selection fires nothing', () {
      final EmacsBuffer model = _uneven();
      int calls = 0;
      model.onSelectionChanged = (Buffer _) => calls++;
      model.switchToBuffer(model.currentBuffer);
      expect(calls, 0);
    });
  });
}
