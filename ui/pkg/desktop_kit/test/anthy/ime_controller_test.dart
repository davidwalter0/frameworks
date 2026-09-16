import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted fake `anthy-agent --egg` (same fixture as anthy_egg_test.dart):
/// any hiragana → 1 segment, candidates ['日本', '二本']. Lets [ImeController]
/// be exercised end-to-end with zero subprocesses.
class _ScriptedAnthy implements AnthyProcess {
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
    final resp = switch (line.split(' ').first) {
      'NEW-CONTEXT' => ['+OK 1'],
      'CONVERT' => ['+DATA 0 0 1', '2 日本 にほん', ''],
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

/// A scripted fake with TWO segments so segment navigation/resize can be
/// exercised. `CONVERT` yields segments `日本`/`語` (readings `にほん`/`ご`).
/// `RESIZE-SEGMENT` with `dir 0` merges into one segment `日本語`; any other
/// `dir` reverts to the original two. `GET-CANDIDATES` tracks that merged/
/// split state so a segment's candidate list matches whichever conversion is
/// currently active — a real `anthy-agent` would do the same, since the
/// candidates for a segment depend on how the sentence is currently split.
class _MultiSegmentAnthy implements AnthyProcess {
  late final StreamController<String> _out = StreamController<String>.broadcast(
    onListen: () => scheduleMicrotask(
      () => _emit('Anthy (Version fake) [] : Nice to meet you.'),
    ),
  );

  /// Whether the sentence is currently merged into one segment (after a
  /// `dir 0` resize) or split into the original two.
  bool _merged = false;

  void _emit(String line) {
    if (!_out.isClosed) _out.add(line);
  }

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    final parts = line.split(' ');
    final resp = switch (parts.first) {
      'NEW-CONTEXT' => <String>['+OK 1'],
      'CONVERT' => () {
          _merged = false;
          return <String>[
            '+DATA 0 0 2',
            '2 日本 にほん',
            '1 語 ご',
            '',
          ];
        }(),
      'GET-CANDIDATES' => _merged
          ? (parts[2] == '0'
              ? <String>['+DATA 1 1', '日本語', '']
              : <String>['+DATA 1 0', ''])
          : switch (parts[2]) {
              '0' => <String>['+DATA 1 2', '日本', '二本', ''],
              '1' => <String>['+DATA 1 1', '語', ''],
              _ => <String>['+DATA 1 0', ''],
            },
      'SELECT-CANDIDATE' => <String>['+OK'],
      'RESIZE-SEGMENT' => () {
          _merged = parts[3] == '0';
          return _merged
              ? <String>['+DATA 1 0 1', '3 日本語 にほんご', '']
              : <String>[
                  '+DATA 1 0 2',
                  '2 日本 にほん',
                  '1 語 ご',
                  '',
                ];
        }(),
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
  group('ImeController state machine (with the scripted backend)', () {
    test('feedKana → space converts → space cycles → commit', () async {
      final ime = ImeController(AnthyEgg(_ScriptedAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      expect(ime.state.phase, ImePhase.composing);
      expect(ime.state.preedit, 'にほん');
      expect(ime.state.displayText, 'にほん');

      await ime.space(); // convert
      expect(ime.state.phase, ImePhase.converting);
      expect(ime.state.candidates, ['日本', '二本']);
      expect(ime.state.candidateIndex, 0);
      expect(ime.state.displayText, '日本');

      await ime.space(); // cycle forward
      expect(ime.state.candidateIndex, 1);
      expect(ime.state.displayText, '二本');

      final committed = await ime.commit();
      expect(committed, '二本');
      expect(ime.state.phase, ImePhase.idle);
    });

    test('Esc cancels back to the raw hiragana', () async {
      final ime = ImeController(AnthyEgg(_ScriptedAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space();
      expect(ime.state.phase, ImePhase.converting);

      final raw = ime.cancel();
      expect(raw, 'にほん');
      expect(ime.state.phase, ImePhase.idle);
    });

    test('Backspace while composing drops the last kana', () async {
      final ime = ImeController(AnthyEgg(_ScriptedAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      ime.backspace();
      expect(ime.state.preedit, 'にほ');
      ime.backspace();
      ime.backspace();
      expect(ime.state.phase, ImePhase.idle);
    });
  });

  group('ImeController multi-segment (Phase-2b)', () {
    test('moveSegmentNext/Previous loads the target segment candidates',
        () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほんご');
      await ime.space(); // convert -> segment 0 active
      expect(ime.state.activeSegment, 0);
      expect(ime.state.candidates, ['日本', '二本']);
      expect(ime.state.displayText, '日本語');

      await ime.moveSegmentNext();
      expect(ime.state.activeSegment, 1);
      expect(ime.state.candidates, ['語']);
      expect(ime.state.displayText, '日本語');

      // Already on the last segment: no-op (does not wrap).
      await ime.moveSegmentNext();
      expect(ime.state.activeSegment, 1);

      await ime.moveSegmentPrevious();
      expect(ime.state.activeSegment, 0);
      expect(ime.state.candidates, ['日本', '二本']);

      // Already on segment 0: no-op.
      await ime.moveSegmentPrevious();
      expect(ime.state.activeSegment, 0);
    });

    test('moveSegmentNext/Previous is a no-op outside converting', () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      // idle
      await ime.moveSegmentNext();
      expect(ime.state.phase, ImePhase.idle);

      // composing
      ime.feedKana('にほんご');
      await ime.moveSegmentNext();
      expect(ime.state.phase, ImePhase.composing);
      expect(ime.state.activeSegment, 0);
    });

    test('growSegment merges segments and reloads the active segment',
        () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほんご');
      await ime.space(); // segment 0 active, 2 segments

      await ime.growSegment();
      expect(ime.state.activeSegment, 0);
      expect(ime.state.candidates, ['日本語']);
      expect(ime.state.displayText, '日本語');
    });

    test('growSegment clamps the active segment when the count shrinks',
        () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほんご');
      await ime.space();
      await ime.moveSegmentNext(); // active segment 1
      expect(ime.state.activeSegment, 1);

      await ime.growSegment(); // re-segments to 1 segment; clamp to 0
      expect(ime.state.activeSegment, 0);
      expect(ime.state.candidates, ['日本語']);
    });

    test('shrinkSegment re-segments and keeps candidates in sync', () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほんご');
      await ime.space();
      await ime.growSegment(); // now 1 segment
      await ime.shrinkSegment(); // back to 2 segments
      expect(ime.state.activeSegment, 0);
      expect(ime.state.candidates, ['日本', '二本']);
      expect(ime.state.displayText, '日本語');
    });

    test('grow/shrinkSegment is a no-op outside converting', () async {
      final ime = ImeController(AnthyEgg(_MultiSegmentAnthy()));
      addTearDown(ime.dispose);

      await ime.growSegment();
      expect(ime.state.phase, ImePhase.idle);

      ime.feedKana('にほんご');
      await ime.shrinkSegment();
      expect(ime.state.phase, ImePhase.composing);
    });
  });
}
