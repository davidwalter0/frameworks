import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted fake that RECORDS every line sent to it, so a test can assert the
/// egg-protocol COMMIT *mode* (0 = learn, 1 = discard) that actually reached
/// Anthy — the one observable difference between [ImeController.commit] and
/// [ImeController.discard]. Any hiragana → 1 segment, candidates ['日本','二本'].
class _RecordingAnthy implements AnthyProcess {
  final List<String> sent = <String>[];

  late final StreamController<String> _out = StreamController<String>.broadcast(
    onListen: () => scheduleMicrotask(
      () => _emit('Anthy (Version fake) [] : Nice to meet you.'),
    ),
  );

  void _emit(String line) {
    if (!_out.isClosed) _out.add(line);
  }

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    sent.add(line);
    final resp = switch (line.split(' ').first) {
      'NEW-CONTEXT' => <String>['+OK 1'],
      'CONVERT' => <String>['+DATA 0 0 1', '2 日本 にほん', ''],
      'GET-CANDIDATES' => <String>['+DATA 1 2', '日本', '二本', ''],
      'SELECT-CANDIDATE' => <String>['+OK'],
      'COMMIT' => <String>['+OK'],
      'RELEASE-CONTEXT' => <String>['+OK'],
      _ => <String>['-ERR unexpected: $line'],
    };
    scheduleMicrotask(() => resp.forEach(_emit));
  }

  @override
  Future<void> kill() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  group('ImeController.discard (Anthy-clean abandon)', () {
    test(
        'while converting: issues COMMIT mode 1 (learn:false), returns reading',
        () async {
      final anthy = _RecordingAnthy();
      final ime = ImeController(AnthyEgg(anthy));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space(); // → converting
      expect(ime.state.phase, ImePhase.converting);

      final raw = await ime.discard();
      expect(raw, 'にほん',
          reason: 'the raw reading is returned for the caller to keep or drop');
      expect(ime.state.phase, ImePhase.idle);
      expect(anthy.sent, contains('COMMIT 1 1'),
          reason: 'mode 1 = discard: abandoned candidates never train Anthy');
      expect(anthy.sent, isNot(contains('COMMIT 1 0')),
          reason: 'discard must never learn (mode 0)');
    });

    test('while composing: local reset, no egg COMMIT at all', () async {
      final anthy = _RecordingAnthy();
      final ime = ImeController(AnthyEgg(anthy));
      addTearDown(ime.dispose);

      ime.feedKana('にほん'); // composing — no CONVERT issued yet
      final raw = await ime.discard();
      expect(raw, 'にほん');
      expect(ime.state.phase, ImePhase.idle);
      expect(anthy.sent.where((String l) => l.startsWith('COMMIT')), isEmpty,
          reason: 'no live conversion while composing → nothing to discard');
    });

    test('contrast: commit() learns via COMMIT mode 0', () async {
      final anthy = _RecordingAnthy();
      final ime = ImeController(AnthyEgg(anthy));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space();
      final committed = await ime.commit();
      expect(committed, '日本');
      expect(anthy.sent, contains('COMMIT 1 0'),
          reason: 'commit learns (mode 0) — the opposite of discard');
    });
  });
}
