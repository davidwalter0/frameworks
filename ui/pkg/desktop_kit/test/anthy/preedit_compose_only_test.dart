import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [PreeditHost] over a mutable (text, caret) with
/// `EmacsBuffer.replaceBeforeCaret` semantics.
class _FakeHost implements PreeditHost {
  String _text = '';
  int _caret = 0;

  @override
  String get text => _text;

  @override
  int get caret => _caret;

  @override
  void applyPreeditSplice(PreeditSplice splice) {
    final int start = (_caret - splice.deleteBefore).clamp(0, _text.length);
    _text = _text.substring(0, start) + splice.insert + _text.substring(_caret);
    _caret = start + splice.insert.length;
  }

  @override
  String readRegion(PreeditRegion region) {
    final int start = region.start.clamp(0, _text.length);
    final int end = (region.start + region.length).clamp(start, _text.length);
    return _text.substring(start, end);
  }
}

void main() {
  group('compose-only session (NullAnthyProcess — no anthy-agent)', () {
    late _FakeHost host;
    late PreeditSession session;

    setUp(() {
      host = _FakeHost();
      session = PreeditSession(
        host,
        ImeController(AnthyEgg(const NullAnthyProcess())),
      );
    });

    tearDown(() => session.dispose());

    test('romaji→kana composes into the host with no subprocess', () async {
      for (final String c in <String>['n', 'i', 'h', 'o']) {
        session.feed(c);
      }
      expect(host.text, 'にほ');
      expect(session.state.phase, PreeditPhase.composing);

      session.feed('n'); // pending tail is still tracked
      expect(host.text, 'にほn');
      expect(session.state.region.pendingRomajiLength, 1);
    });

    test('Shift+K flips the composing kana without a controller round-trip',
        () async {
      session.feedKana('にほん');
      session.toggleScript();
      expect(host.text, 'ニホン');
      expect(session.state.phase, PreeditPhase.composing);
    });

    test('backspace trims the tail, then kana', () async {
      session.feed('n');
      session.feed('i'); // に
      session.feed('s'); // + pending s
      expect(host.text, 'にs');

      session.backspace();
      expect(host.text, 'に');
      session.backspace();
      expect(host.text, '');
      expect(session.state.phase, PreeditPhase.idle);
    });

    test('Enter commits the composed kana and exits — the whole point',
        () async {
      session.feed('n');
      session.feed('i');
      session.feed('h');
      session.feed('o');
      session.feed('n');

      final PreeditOutcome out = await session.commit();
      // The trailing lone `n` flushes to ん, so the committed reading is にほん.
      expect(out.committed, 'にほん');
      expect(host.text, 'にほん');
      expect(session.state.phase, PreeditPhase.idle);
      expect(session.state.region.isEmpty, isTrue);
    });

    test('discard drops the composition without touching the transport',
        () async {
      session.feedKana('にほん');
      final PreeditOutcome out = await session.discard();
      expect(out.reverted, 'にほん');
      expect(host.text, '');
      expect(session.state.phase, PreeditPhase.idle);
    });

    test('an accidental conversion attempt fails FAST, never hangs', () async {
      session.feedKana('にほん');
      // The backstop: `lines` is closed, so AnthyEgg.start() cannot receive its
      // greeting and errors out promptly instead of awaiting one forever.
      await expectLater(session.space(), throwsA(anything));
    });
  });
}
