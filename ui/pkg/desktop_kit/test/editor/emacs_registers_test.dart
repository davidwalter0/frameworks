// Thorough headless tests for Registers and MacroRecorder. Expectations
// below are hand-derived from Emacs register / keyboard-macro semantics, not
// copied from the implementation.
import 'package:desktop_kit/desktop_kit_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Registers', () {
    test('unknown register returns null', () {
      final r = Registers();
      expect(r.get('a'), isNull);
    });

    test('put then get round-trips a value', () {
      final r = Registers();
      r.put('a', 'hello');
      expect(r.get('a'), 'hello');
    });

    test('put overwrites a previous value under the same name', () {
      final r = Registers();
      r.put('a', 'first');
      r.put('a', 'second');
      expect(r.get('a'), 'second');
    });

    test('different names are independent', () {
      final r = Registers();
      r.put('a', 'one');
      r.put('b', 'two');
      expect(r.get('a'), 'one');
      expect(r.get('b'), 'two');
    });

    test('all reflects every stored register', () {
      final r = Registers();
      r.put('a', 'one');
      r.put('b', 'two');
      expect(r.all, <String, String>{'a': 'one', 'b': 'two'});
    });

    test('all is empty when nothing has been put', () {
      final r = Registers();
      expect(r.all, isEmpty);
    });

    test('all is unmodifiable', () {
      final r = Registers();
      r.put('a', 'one');
      expect(() => r.all['a'] = 'tampered', throwsUnsupportedError);
    });
  });

  group('MacroRecorder', () {
    test('initial state: not recording, no macro, no steps', () {
      final m = MacroRecorder();
      expect(m.recording, isFalse);
      expect(m.hasMacro, isFalse);
      expect(m.steps, isEmpty);
    });

    test('record is a no-op when not recording', () {
      final m = MacroRecorder();
      m.record('moveForwardChar');
      expect(m.steps, isEmpty);
      expect(m.recording, isFalse);
    });

    test('start begins recording with empty steps', () {
      final m = MacroRecorder();
      m.start();
      expect(m.recording, isTrue);
      expect(m.steps, isEmpty);
    });

    test('record appends steps while recording', () {
      final m = MacroRecorder();
      m.start();
      m.record('moveForwardChar');
      m.record('self-insert:x');
      expect(m.steps, <String>['moveForwardChar', 'self-insert:x']);
      expect(m.recording, isTrue);
    });

    test('end is a no-op when not recording', () {
      final m = MacroRecorder();
      m.end();
      expect(m.recording, isFalse);
      expect(m.hasMacro, isFalse);
    });

    test('end stops recording and makes the macro available to replay', () {
      final m = MacroRecorder();
      m.start();
      m.record('moveForwardChar');
      m.record('moveForwardChar');
      m.end();
      expect(m.recording, isFalse);
      expect(m.hasMacro, isTrue);
      expect(m.replay(), <String>['moveForwardChar', 'moveForwardChar']);
    });

    test('replay before any macro is recorded returns an empty list', () {
      final m = MacroRecorder();
      expect(m.replay(), isEmpty);
    });

    test('record after end (before a new start) is a no-op', () {
      final m = MacroRecorder();
      m.start();
      m.record('a');
      m.end();
      m.record('b');
      expect(m.replay(), <String>['a']);
    });

    test('start after end discards prior in-progress steps and begins fresh',
        () {
      final m = MacroRecorder();
      m.start();
      m.record('a');
      m.end();
      m.start();
      expect(m.steps, isEmpty);
      m.record('b');
      m.end();
      expect(m.replay(), <String>['b']);
    });

    test(
        'starting a new recording mid-recording discards the old in-progress steps',
        () {
      final m = MacroRecorder();
      m.start();
      m.record('a');
      m.start();
      expect(m.steps, isEmpty);
      m.record('b');
      m.end();
      expect(m.replay(), <String>['b']);
    });

    test(
        'replay after a fresh start reflects only the new steps, not a stale macro',
        () {
      final m = MacroRecorder();
      m.start();
      m.record('old1');
      m.record('old2');
      m.end();
      expect(m.replay(), <String>['old1', 'old2']);

      m.start();
      m.record('new1');
      m.end();
      expect(m.replay(), <String>['new1']);
    });

    test('steps getter is unmodifiable', () {
      final m = MacroRecorder();
      m.start();
      m.record('a');
      expect(() => m.steps.add('tampered'), throwsUnsupportedError);
    });

    test(
        'replay returns a fresh list each call (mutating it does not affect the macro)',
        () {
      final m = MacroRecorder();
      m.start();
      m.record('a');
      m.end();
      final first = m.replay();
      first.add('mutated');
      expect(m.replay(), <String>['a']);
    });
  });
}
