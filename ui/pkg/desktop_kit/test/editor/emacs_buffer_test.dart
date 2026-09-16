// Thorough headless tests for the pure EmacsBuffer model. Expectations below
// are hand-derived from the behavioural spec (TextMotions / KillRing /
// MarkState semantics), not copied from the implementation.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('insert / caret basics', () {
    test('insert advances caret and splices text', () {
      final b = EmacsBuffer(text: 'hello', caret: 5);
      b.insert(' world');
      expect(b.text, 'hello world');
      expect(b.caret, 11);
    });

    test('insert in the middle splices correctly', () {
      final b = EmacsBuffer(text: 'ac', caret: 1);
      b.insert('b');
      expect(b.text, 'abc');
      expect(b.caret, 2);
    });

    test('caret setter clamps to [0, text.length]', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.caret = 100;
      expect(b.caret, 3);
      b.caret = -5;
      expect(b.caret, 0);
    });

    test('constructor clamps an out-of-range initial caret', () {
      final b = EmacsBuffer(text: 'abc', caret: 99);
      expect(b.caret, 3);
    });
  });

  group('backspace', () {
    test('deletes the char before caret and moves caret back', () {
      final b = EmacsBuffer(text: 'hello', caret: 5);
      b.backspace();
      expect(b.text, 'hell');
      expect(b.caret, 4);
    });

    test('no-ops at the beginning of buffer (no undo pushed)', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.backspace();
      expect(b.text, 'abc');
      expect(b.caret, 0);
      expect(b.canUndo, isFalse);
    });
  });

  group('motions', () {
    test('moveLineStart / moveLineEnd within a multi-line buffer', () {
      // "abc\ndef\nghi" -> a0 b1 c2 \n3 d4 e5 f6 \n7 g8 h9 i10
      final b = EmacsBuffer(text: 'abc\ndef\nghi', caret: 6);
      expect(b.execute('moveLineStart'), isTrue);
      expect(b.caret, 4);
      b.caret = 6;
      expect(b.execute('moveLineEnd'), isTrue);
      expect(b.caret, 7);
    });

    test('moveForwardChar / moveBackwardChar', () {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      expect(b.execute('moveForwardChar'), isTrue);
      expect(b.caret, 2);
      expect(b.execute('moveBackwardChar'), isTrue);
      expect(b.caret, 1);
    });

    test('moveForwardWord skips to end of first word', () {
      final b = EmacsBuffer(text: 'foo bar baz', caret: 0);
      expect(b.execute('moveForwardWord'), isTrue);
      expect(b.caret, 3);
    });

    test('moveBackwardWord from end lands at start of last word', () {
      final b = EmacsBuffer(text: 'foo bar baz', caret: 11);
      expect(b.execute('moveBackwardWord'), isTrue);
      expect(b.caret, 8);
    });

    test('moveNextLine / movePreviousLine track column', () {
      // "ab\ncdef" -> a0 b1 \n2 c3 d4 e5 f6
      final b = EmacsBuffer(text: 'ab\ncdef', caret: 1); // column 1, line 0
      expect(b.execute('moveNextLine'), isTrue);
      expect(b.caret, 4); // line 1 start (3) + col 1
      expect(b.execute('movePreviousLine'), isTrue);
      expect(b.caret, 1);
    });

    test('moveBufferStart / moveBufferEnd', () {
      final b = EmacsBuffer(text: 'hello world', caret: 5);
      expect(b.execute('moveBufferStart'), isTrue);
      expect(b.caret, 0);
      expect(b.execute('moveBufferEnd'), isTrue);
      expect(b.caret, 11);
    });

    test('motions do not push undo history', () {
      final b = EmacsBuffer(text: 'hello world', caret: 0);
      b.execute('moveForwardWord');
      expect(b.canUndo, isFalse);
    });

    test('motions break the kill sequence', () {
      final b = EmacsBuffer(text: 'abc\ndef', caret: 0);
      b.execute('killLine'); // kills "abc", lastWasKill becomes true
      expect(b.killRing.lastWasKill, isTrue);
      b.execute('moveForwardChar');
      expect(b.killRing.lastWasKill, isFalse);
    });
  });

  group('mark / region', () {
    test('region/regionText are null with no mark', () {
      final b = EmacsBuffer(text: 'hello', caret: 2);
      expect(b.region, isNull);
      expect(b.regionText, isNull);
    });

    test('setMark then move exposes a normalized region', () {
      final b = EmacsBuffer(text: 'hello world', caret: 0);
      expect(b.execute('setMark'), isTrue);
      expect(b.mark.mark, 0);
      b.execute('moveForwardWord'); // caret -> 5
      expect(b.region, const Region(0, 5));
      expect(b.regionText, 'hello');
    });

    test('exchangePointAndMark swaps caret and mark', () {
      final b = EmacsBuffer(text: 'abcdef', caret: 2);
      b.execute('setMark'); // mark = 2
      b.execute('moveForwardChar'); // caret = 3
      expect(b.execute('exchangePointAndMark'), isTrue);
      expect(b.caret, 2); // old mark
      expect(b.mark.mark, 3); // old caret
    });

    test('exchangePointAndMark is a no-op with no mark set', () {
      final b = EmacsBuffer(text: 'abcdef', caret: 2);
      expect(b.execute('exchangePointAndMark'), isTrue);
      expect(b.caret, 2);
    });

    test('markWholeBuffer marks the entire buffer and homes the caret', () {
      final b = EmacsBuffer(text: 'hello', caret: 2);
      expect(b.execute('markWholeBuffer'), isTrue);
      expect(b.mark.mark, 5);
      expect(b.caret, 0);
      expect(b.regionText, 'hello');
    });

    test('markPage behaves like markWholeBuffer', () {
      final b = EmacsBuffer(text: 'hello', caret: 2);
      expect(b.execute('markPage'), isTrue);
      expect(b.mark.mark, 5);
      expect(b.caret, 0);
    });
  });

  group('kill / yank', () {
    test('killRegion deletes the region and pushes it to the kill ring', () {
      final b = EmacsBuffer(text: 'hello world', caret: 0);
      b.execute('setMark');
      b.execute('moveForwardWord'); // caret -> 5, region [0,5) = "hello"
      expect(b.execute('killRegion'), isTrue);
      expect(b.text, ' world');
      expect(b.caret, 0);
      expect(b.killRing.entries.first, 'hello');
      expect(b.mark.hasMark, isFalse);
    });

    test('killRegion with no mark is a no-op', () {
      final b = EmacsBuffer(text: 'hello world', caret: 3);
      expect(b.execute('killRegion'), isTrue);
      expect(b.text, 'hello world');
      expect(b.caret, 3);
    });

    test('copyRegion copies without deleting and clears the mark', () {
      final b = EmacsBuffer(text: 'hello world', caret: 0);
      b.execute('setMark');
      b.execute('moveForwardWord'); // caret -> 5
      expect(b.execute('copyRegion'), isTrue);
      expect(b.text, 'hello world'); // unchanged
      expect(b.caret, 5); // unchanged by copy
      expect(b.killRing.entries.first, 'hello');
      expect(b.mark.hasMark, isFalse);
    });

    test('killLine then yank round-trips the killed text', () {
      final b = EmacsBuffer(text: 'hello world', caret: 0);
      expect(b.execute('killLine'), isTrue);
      expect(b.text, '');
      expect(b.caret, 0);
      expect(b.execute('yank'), isTrue);
      expect(b.text, 'hello world');
      expect(b.caret, 11);
    });

    test('killLine at end-of-line joins the following line', () {
      // "abc\ndef" -> caret 3 sits right before the newline.
      final b = EmacsBuffer(text: 'abc\ndef', caret: 3);
      expect(b.execute('killLine'), isTrue);
      expect(b.text, 'abcdef');
      expect(b.caret, 3);
      expect(b.killRing.entries.first, '\n');
    });

    test('consecutive killLine calls merge into one kill-ring entry', () {
      // "abc\ndef\nghi" -> a0 b1 c2 \n3 d4 e5 f6 \n7 g8 h9 i10
      final b = EmacsBuffer(text: 'abc\ndef\nghi', caret: 0);
      b.execute('killLine'); // kills "abc" -> text becomes "\ndef\nghi"
      expect(b.text, '\ndef\nghi');
      b.execute('killLine'); // kills the leading "\n" -> merges with "abc"
      expect(b.text, 'def\nghi');
      expect(b.killRing.entries.length, 1);
      expect(b.killRing.entries.first, 'abc\n');
    });

    test('killWholeLine removes the line plus trailing newline', () {
      // "abc\ndef\nghi" caret at 5 ('e' in "def").
      final b = EmacsBuffer(text: 'abc\ndef\nghi', caret: 5);
      expect(b.execute('killWholeLine'), isTrue);
      expect(b.text, 'abc\nghi');
      expect(b.caret, 4);
      expect(b.killRing.entries.first, 'def\n');
    });

    test('deleteChar removes the char at caret without touching the kill ring',
        () {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      expect(b.execute('deleteChar'), isTrue);
      expect(b.text, 'ac');
      expect(b.caret, 1);
      expect(b.killRing.isEmpty, isTrue);
    });

    test('deleteChar at end of buffer is a no-op', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      expect(b.execute('deleteChar'), isTrue);
      expect(b.text, 'abc');
      expect(b.caret, 3);
    });

    test('deleteWordForward kills the next word', () {
      final b = EmacsBuffer(text: 'foo bar', caret: 0);
      expect(b.execute('deleteWordForward'), isTrue);
      expect(b.text, ' bar');
      expect(b.caret, 0);
      expect(b.killRing.entries.first, 'foo');
    });

    test('deleteWordBackward kills the previous word (prepend merge order)',
        () {
      final b = EmacsBuffer(text: 'hello world', caret: 11);
      expect(b.execute('deleteWordBackward'), isTrue);
      expect(b.text, 'hello ');
      expect(b.caret, 6);
      expect(b.killRing.entries.first, 'world');
    });

    test('deleteWordBackward twice prepends onto the front entry', () {
      // "foo bar baz" caret at end(11): first kill "baz", caret->8;
      // second kill "bar " (word run + trailing separator) prepended.
      final b = EmacsBuffer(text: 'foo bar baz', caret: 11);
      b.execute('deleteWordBackward'); // kills "baz" -> "foo bar "
      expect(b.text, 'foo bar ');
      expect(b.caret, 8);
      b.execute(
          'deleteWordBackward'); // backwardWord(text,8) -> span [4,8) = "bar "
      expect(b.text, 'foo ');
      expect(b.caret, 4);
      expect(b.killRing.entries.length, 1);
      expect(b.killRing.entries.first, 'bar baz');
    });

    test('yank then yankPop swaps in the previous ring entry', () {
      final b = EmacsBuffer(text: 'one two', caret: 0);
      b.execute('setMark'); // mark = 0
      b.execute('moveForwardWord'); // caret -> 3 ("one")
      b.execute('killRegion'); // kills "one" -> text=" two", ring=["one"]
      expect(b.text, ' two');

      b.execute('setMark'); // mark = 0 (fresh mark on current caret 0)
      b.execute('moveForwardWord'); // caret -> 4 (" two")
      b.execute('killRegion'); // kills " two" -> text="", ring=[" two","one"]
      expect(b.text, '');
      expect(b.killRing.entries, [' two', 'one']);

      expect(b.execute('yank'), isTrue);
      expect(b.text, ' two');
      expect(b.caret, 4);

      expect(b.execute('yankPop'), isTrue);
      expect(b.text, 'one');
      expect(b.caret, 3);
    });

    test('yankPop without a preceding yank is a no-op', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.killRing.kill('xyz');
      expect(b.execute('yankPop'), isTrue);
      expect(b.text, 'abc');
      expect(b.caret, 0);
    });

    test('yank with an empty kill ring inserts nothing', () {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      expect(b.killRing.isEmpty, isTrue);
      expect(b.execute('yank'), isTrue);
      expect(b.text, 'abc');
      expect(b.caret, 1);
    });
  });

  group('editing commands', () {
    test('openLine inserts a newline but keeps the caret in place', () {
      final b = EmacsBuffer(text: 'ab', caret: 1);
      expect(b.execute('openLine'), isTrue);
      expect(b.text, 'a\nb');
      expect(b.caret, 1);
    });

    test('transposeChars swaps the two chars around caret mid-buffer', () {
      // "abcd" caret=2 (between 'b' and 'c') -> swaps index1<->index2.
      final b = EmacsBuffer(text: 'abcd', caret: 2);
      expect(b.execute('transposeChars'), isTrue);
      expect(b.text, 'acbd');
      expect(b.caret, 3);
    });

    test('transposeChars at end of buffer swaps the final two chars', () {
      final b = EmacsBuffer(text: 'abcd', caret: 4);
      expect(b.execute('transposeChars'), isTrue);
      expect(b.text, 'abdc');
      expect(b.caret, 4);
    });

    test('transposeChars is a no-op when the buffer is too short', () {
      final b = EmacsBuffer(text: 'a', caret: 1);
      expect(b.execute('transposeChars'), isTrue);
      expect(b.text, 'a');
      expect(b.caret, 1);
    });

    test('upcaseWord uppercases the word at caret and moves to its end', () {
      final b = EmacsBuffer(text: 'hello World', caret: 0);
      expect(b.execute('upcaseWord'), isTrue);
      expect(b.text, 'HELLO World');
      expect(b.caret, 5);
    });

    test('downcaseWord lowercases the word at caret', () {
      final b = EmacsBuffer(text: 'Hello WORLD', caret: 6);
      expect(b.execute('downcaseWord'), isTrue);
      expect(b.text, 'Hello world');
      expect(b.caret, 11);
    });

    test('capitalizeWord title-cases the word at caret', () {
      final b = EmacsBuffer(text: 'fOO bar', caret: 0);
      expect(b.execute('capitalizeWord'), isTrue);
      expect(b.text, 'Foo bar');
      expect(b.caret, 3);
    });

    test('justOneSpace collapses surrounding whitespace to one space', () {
      // "a   b" caret=2 (middle of the 3 spaces).
      final b = EmacsBuffer(text: 'a   b', caret: 2);
      expect(b.execute('justOneSpace'), isTrue);
      expect(b.text, 'a b');
      expect(b.caret, 2);
    });

    test('justOneSpace with tabs mixed in around caret', () {
      // "a \t b" caret=2 -> whitespace run [1,4) collapses to one space.
      final b = EmacsBuffer(text: 'a \t b', caret: 2);
      expect(b.execute('justOneSpace'), isTrue);
      expect(b.text, 'a b');
      expect(b.caret, 2);
    });

    test('deleteHorizontalSpace removes all surrounding whitespace', () {
      final b = EmacsBuffer(text: 'a   b', caret: 2);
      expect(b.execute('deleteHorizontalSpace'), isTrue);
      expect(b.text, 'ab');
      expect(b.caret, 1);
    });
  });

  group('undo / redo', () {
    test('undo restores the previous text and caret; redo replays it', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      b.insert('X');
      expect(b.text, 'abcX');
      expect(b.caret, 4);
      expect(b.canUndo, isTrue);

      expect(b.execute('undo'), isTrue);
      expect(b.text, 'abc');
      expect(b.caret, 3);
      expect(b.canRedo, isTrue);

      expect(b.execute('redo'), isTrue);
      expect(b.text, 'abcX');
      expect(b.caret, 4);
    });

    test('undo with empty history is a no-op', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      expect(b.canUndo, isFalse);
      expect(b.execute('undo'), isTrue);
      expect(b.text, 'abc');
    });

    test('redo with empty history is a no-op', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      expect(b.canRedo, isFalse);
      expect(b.execute('redo'), isTrue);
      expect(b.text, 'abc');
    });

    test('a new edit after undo clears the redo stack', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      b.insert('X'); // -> "abcX"
      b.execute('undo'); // -> "abc"
      b.insert('Y'); // -> "abcY", new edit branch
      expect(b.text, 'abcY');
      expect(b.canRedo, isFalse);
    });

    test('multiple undos restore multiple snapshots in order', () {
      final b = EmacsBuffer(text: '', caret: 0);
      b.insert('a');
      b.insert('b');
      b.insert('c');
      expect(b.text, 'abc');
      b.execute('undo');
      expect(b.text, 'ab');
      b.execute('undo');
      expect(b.text, 'a');
      b.execute('undo');
      expect(b.text, '');
      expect(b.canUndo, isFalse);
    });
  });

  group('replaceBeforeCaret', () {
    test('deletes N characters before the caret and inserts new text', () {
      final b = EmacsBuffer(text: 'abcXYZ', caret: 4); // caret after 'X'
      b.replaceBeforeCaret(1, 'QQ'); // replace the 'X' with "QQ"
      expect(b.text, 'abcQQYZ');
      expect(b.caret, 5);
    });

    test('deleteBefore 0 is a pure insert at the caret', () {
      final b = EmacsBuffer(text: 'ac', caret: 1);
      b.replaceBeforeCaret(0, 'b');
      expect(b.text, 'abc');
      expect(b.caret, 2);
    });

    test('empty insert with deleteBefore > 0 is a pure delete', () {
      final b = EmacsBuffer(text: 'abcd', caret: 4);
      b.replaceBeforeCaret(2, '');
      expect(b.text, 'ab');
      expect(b.caret, 2);
    });

    test('no-op (no undo push) when nothing to delete and nothing to insert',
        () {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      b.replaceBeforeCaret(0, '');
      expect(b.text, 'abc');
      expect(b.canUndo, isFalse);
    });

    test('deleteBefore beyond the caret clamps to the start', () {
      final b = EmacsBuffer(text: 'ab', caret: 1);
      b.replaceBeforeCaret(99, 'X');
      expect(b.text, 'Xb');
      expect(b.caret, 1);
    });

    test('pushes its own undo step by default (coalesce: false)', () {
      final b = EmacsBuffer(text: '', caret: 0);
      b.replaceBeforeCaret(0, 'a');
      b.replaceBeforeCaret(1, 'b'); // second push, replacing the 'a'
      expect(b.text, 'b');
      b.execute('undo');
      expect(b.text, 'a');
      b.execute('undo');
      expect(b.text, '');
    });

    test(
        'coalesce: true merges into the current undo step instead of '
        'pushing a new one', () {
      final b = EmacsBuffer(text: '', caret: 0);
      b.replaceBeforeCaret(0, 'n'); // first keystroke: pushes ONE snapshot
      b.replaceBeforeCaret(1, 'に', coalesce: true); // coalesced — no new push
      b.replaceBeforeCaret(1, 'にほ', coalesce: true); // still coalesced
      expect(b.text, 'にほ');
      // One undo restores all the way back to the pre-run empty buffer —
      // proof the whole run collapsed into a single undo step.
      expect(b.execute('undo'), isTrue);
      expect(b.text, '');
      expect(b.canUndo, isFalse);
    });

    test(
        'coalesce: true with an empty undo stack still pushes (nothing to '
        'coalesce into)', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      b.replaceBeforeCaret(0, 'X', coalesce: true);
      expect(b.text, 'abcX');
      expect(b.canUndo, isTrue);
      b.execute('undo');
      expect(b.text, 'abc');
    });

    test('adjusts the mark for the net length delta', () {
      final b = EmacsBuffer(text: 'abcdef', caret: 6);
      b.execute('setMark'); // mark at 6, point will move
      b.caret = 3;
      b.replaceBeforeCaret(1, 'XY'); // replace 'c' with "XY": net +1
      expect(b.text, 'abXYdef');
      // The mark sat after the edit point, so it shifts by the net delta.
      expect(b.mark.mark, 7);
    });
  });

  group('recordSelfInsert', () {
    test('records a self-insert macro step without touching the buffer', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      b.execute('startMacro');
      b.recordSelfInsert('にほん');
      b.execute('endMacro');
      expect(b.text, 'abc', reason: 'recordSelfInsert never mutates text');

      // Replaying the macro performs the insert the recorded step describes.
      b.execute('callMacro');
      expect(b.text, 'abcにほん');
    });

    test('is a no-op when no macro is being recorded', () {
      final b = EmacsBuffer(text: 'abc', caret: 3);
      // No exception, no crash, nothing recorded — callMacro finds nothing.
      b.recordSelfInsert('x');
      expect(b.execute('callMacro'), isTrue);
      expect(b.status, 'No kbd macro has been defined');
    });
  });

  group('report-only commands', () {
    test('keyboardQuit clears the mark and sets status', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.execute('setMark');
      expect(b.mark.hasMark, isTrue);
      expect(b.execute('keyboardQuit'), isTrue);
      expect(b.mark.hasMark, isFalse);
      expect(b.status, 'Quit');
    });

    test('save/help/recenter etc. do not mutate the buffer', () {
      final b = EmacsBuffer(text: 'abc', caret: 1);
      for (final id in [
        'save',
        'openFile',
        'switchBuffer',
        'killBuffer',
        'help',
        'browseKillRing',
        'recenter',
      ]) {
        expect(b.execute(id), isTrue, reason: id);
        expect(b.text, 'abc');
        expect(b.caret, 1);
        expect(b.canUndo, isFalse);
      }
    });
  });

  group('unknown intents', () {
    test('unrecognized intent id returns false and reports it', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      expect(b.execute('totallyBogusIntent'), isFalse);
      expect(b.status, contains('totallyBogusIntent'));
      expect(b.text, 'abc');
    });
  });

  // The minibuffer is a buffer, so it needs its own undo/yank verbs, scoped
  // to the ACTIVE prompt's text — never the buffer sitting behind it (mgmt
  // todo af1d77bb / c05ceaa9).
  group('minibuffer prompt undo/yank (promptUndo / promptYank)', () {
    test('promptUndo undoes prompt text edits without touching the buffer', () {
      final b = EmacsBuffer(text: 'BUFFER TEXT UNCHANGED', caret: 0);
      expect(b.execute('executeExtendedCommand'), isTrue);
      b.promptChar('a');
      b.promptChar('b');
      expect(b.prompt, 'M-x ab');

      b.promptUndo();
      expect(b.prompt, 'M-x a');
      expect(b.text, 'BUFFER TEXT UNCHANGED');

      b.promptUndo();
      expect(b.prompt, 'M-x ');
      expect(b.text, 'BUFFER TEXT UNCHANGED');

      // Nothing left to undo IN THE PROMPT: no-op, buffer still untouched.
      b.promptUndo();
      expect(b.prompt, 'M-x ');
      expect(b.status, 'No further undo information');
      expect(b.text, 'BUFFER TEXT UNCHANGED');
    });

    test('promptUndo no-ops when no prompt is open — buffer undo untouched',
        () {
      final buf = EmacsBuffer(text: 'abc', caret: 3);
      buf.insert('d'); // one buffer-undo step: 'abc' -> 'abcd'.
      expect(buf.text, 'abcd');
      expect(buf.canUndo, isTrue);

      buf.promptUndo(); // no prompt open: must not reach the buffer's undo.
      expect(buf.text, 'abcd');
      expect(buf.canUndo, isTrue);
    });

    test('promptYank inserts text at the prompt caret in ONE undo step', () {
      final b = EmacsBuffer(text: 'BUFFER UNCHANGED', caret: 0);
      expect(b.execute('executeExtendedCommand'), isTrue);
      b.promptChar('x');
      b.promptYank('KILLED');
      expect(b.prompt, 'M-x xKILLED');
      expect(b.text, 'BUFFER UNCHANGED');

      // A single promptUndo reverts the WHOLE yank at once, not one code
      // unit at a time.
      b.promptUndo();
      expect(b.prompt, 'M-x x');
      expect(b.text, 'BUFFER UNCHANGED');
    });

    test('promptYank no-ops on empty text or when no prompt is open', () {
      final b = EmacsBuffer(text: 'abc', caret: 0);
      b.promptYank('nope'); // no prompt open.
      expect(b.text, 'abc');

      expect(b.execute('executeExtendedCommand'), isTrue);
      b.promptYank('');
      expect(b.prompt, 'M-x ');
    });

    test('prompt undo history is discarded when the prompt closes', () {
      final b = EmacsBuffer(text: 'x', caret: 0);
      expect(b.execute('executeExtendedCommand'), isTrue);
      b.promptChar('a');
      b.promptChar('b');
      b.promptCancel(); // C-g

      // A fresh prompt must not inherit the cancelled one's undo history.
      expect(b.execute('executeExtendedCommand'), isTrue);
      b.promptUndo();
      expect(b.prompt, 'M-x ');
      expect(b.status, 'No further undo information');
    });
  });
}
