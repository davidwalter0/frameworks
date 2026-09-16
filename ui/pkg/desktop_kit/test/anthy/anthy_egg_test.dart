import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted fake `anthy-agent --egg`: emits the startup banner up front, then
/// answers each command line with a canned egg-protocol response. Lets the
/// egg driver be exercised with zero subprocesses.
///
/// Conversion fixture: にほん → 1 segment, candidates ['日本', '二本'].
class _ScriptedAnthy implements AnthyProcess {
  // Broadcast + emit-on-listen so (a) close() always completes even when the
  // egg was never started (no listener), and (b) the banner is produced only
  // once someone subscribes. A plain single-subscription controller with a
  // buffered banner hangs its close() future when never listened.
  late final StreamController<String> _out = StreamController<String>.broadcast(
    onListen: () => scheduleMicrotask(
      () => _emit('Anthy (Version fake) [] : Nice to meet you.'),
    ),
  );
  final List<String> sent = [];

  void _emit(String line) {
    if (!_out.isClosed) _out.add(line);
  }

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    sent.add(line);
    final cmd = line.split(' ').first;
    final resp = switch (cmd) {
      'NEW-CONTEXT' => ['+OK 1'],
      // +DATA <start> <reserved> <nsegments>; then <ncands> <best> <reading>.
      'CONVERT' => ['+DATA 0 0 1', '2 日本 にほん', ''],
      // +DATA <ctx> <ncands>; then the candidate lines.
      'GET-CANDIDATES' => ['+DATA 1 2', '日本', '二本', ''],
      'SELECT-CANDIDATE' => ['+OK'],
      'COMMIT' => ['+OK'],
      'RELEASE-CONTEXT' => ['+OK'],
      _ => ['-ERR unexpected: $line'],
    };
    scheduleMicrotask(() => resp.forEach(_emit));
  }

  @override
  Future<void> kill() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  group('AnthySegment / AnthyConversion parsing', () {
    test('parses a "<ncands> <best> <reading>" segment line', () {
      final seg = AnthySegment.parse('3 日本語 にほんご');
      expect(seg.candidateCount, 3);
      expect(seg.best, '日本語');
      expect(seg.reading, 'にほんご');
    });

    test('conversion text joins each segment best', () {
      const conv = AnthyConversion([
        AnthySegment(candidateCount: 1, best: '日本', reading: 'にほん'),
        AnthySegment(candidateCount: 1, best: '語', reading: 'ご'),
      ]);
      expect(conv.text, '日本語');
    });

    test('a malformed segment line throws AnthyEggException', () {
      expect(
        () => AnthySegment.parse('nope'),
        throwsA(isA<AnthyEggException>()),
      );
    });
  });

  group('AnthyEgg.isAvailable (hermetic PATH probe)', () {
    test('true for a binary always on PATH (sh)', () async {
      expect(await AnthyEgg.isAvailable(executable: 'sh'), isTrue);
    });

    test('false for a nonexistent binary', () async {
      expect(
        await AnthyEgg.isAvailable(
          executable: 'desktop-kit-no-such-binary-xyzzy',
        ),
        isFalse,
      );
    });
  });

  group('AnthyEgg drives the egg protocol', () {
    test('start → convert → candidates → commit', () async {
      final egg = AnthyEgg(_ScriptedAnthy());
      await egg.start();
      expect(egg.contextId, 1);

      final conv = await egg.convert('にほん');
      expect(conv.segments, hasLength(1));
      expect(conv.text, '日本');

      final cands = await egg.candidates(0);
      expect(cands, ['日本', '二本']);

      await egg.selectCandidate(0, 1);
      await egg.commit();
      await egg.close();
    });
  });
}
