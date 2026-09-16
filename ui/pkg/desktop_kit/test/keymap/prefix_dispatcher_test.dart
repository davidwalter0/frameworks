// Tests for PrefixDispatcher — C-x two-stroke chord state machine.
// ignore_for_file: deprecated_member_use
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrefixDispatcher', () {
    test('starts in idle phase', () {
      final d = PrefixDispatcher();
      expect(d.phase, PrefixPhase.idle);
      expect(d.isWaiting, isFalse);
    });

    test('pressCtrlX transitions to afterCtrlX and returns prefixPending', () {
      final d = PrefixDispatcher();
      final cmd = d.pressCtrlX();
      expect(cmd, EditorCommand.prefixPending);
      expect(d.phase, PrefixPhase.afterCtrlX);
      expect(d.isWaiting, isTrue);
    });

    test('pressKey(ctrlS) after C-x returns saveBuffer and returns to idle',
        () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      final cmd = d.pressKey(PrefixKey.ctrlS);
      expect(cmd, EditorCommand.saveBuffer);
      expect(d.phase, PrefixPhase.idle);
    });

    test('pressKey(ctrlF) returns findFile', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.ctrlF), EditorCommand.findFile);
    });

    test('pressKey(ctrlX) returns exchangePointAndMark', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.ctrlX), EditorCommand.exchangePointAndMark);
    });

    test('pressKey(ctrlP) returns markPage', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.ctrlP), EditorCommand.markPage);
    });

    test('pressKey(letterB) returns switchBuffer', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.letterB), EditorCommand.switchBuffer);
    });

    test('pressKey(letterH) returns markWholeBuffer', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.letterH), EditorCommand.markWholeBuffer);
    });

    test('pressKey(letterK) returns killBuffer', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      expect(d.pressKey(PrefixKey.letterK), EditorCommand.killBuffer);
    });

    test('pressKey without prior C-x returns none', () {
      final d = PrefixDispatcher();
      final cmd = d.pressKey(PrefixKey.ctrlS);
      expect(cmd, EditorCommand.none);
    });

    test('cancel while waiting returns true and resets to idle', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      final was = d.cancel();
      expect(was, isTrue);
      expect(d.phase, PrefixPhase.idle);
    });

    test('cancel while idle returns false', () {
      final d = PrefixDispatcher();
      expect(d.cancel(), isFalse);
    });

    test('second pressCtrlX resets back to waiting', () {
      final d = PrefixDispatcher();
      d.pressCtrlX();
      d.pressKey(PrefixKey.ctrlS); // consumed, back to idle
      final cmd = d.pressCtrlX(); // arm again
      expect(cmd, EditorCommand.prefixPending);
      expect(d.isWaiting, isTrue);
    });
  });
}
