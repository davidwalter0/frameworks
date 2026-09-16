import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted fake whose best candidate is itself **kana** — the real-world
/// case for a name / non-dictionary word (e.g. でびどう), where Anthy returns
/// the reading as the top candidate. `CONVERT` of any hiragana → 1 segment with
/// best `にほん`; `GET-CANDIDATES` → [`にほん`, `日本`]. This is what makes the
/// script toggle observable: flipping a kanji candidate would be a no-op.
class _KanaCandidateAnthy implements AnthyProcess {
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
      'NEW-CONTEXT' => <String>['+OK 1'],
      'CONVERT' => <String>['+DATA 0 0 1', '2 にほん にほん', ''],
      'GET-CANDIDATES' => <String>['+DATA 1 2', 'にほん', '日本', ''],
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
  group('ImeController.toggleScript (Shift-K, behavior B)', () {
    test('flips the highlighted kana candidate hiragana→katakana and back',
        () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space(); // convert; best candidate is the kana reading
      expect(ime.state.phase, ImePhase.converting);
      expect(ime.state.candidates, ['にほん', '日本']);
      expect(ime.state.candidateIndex, 0);
      expect(ime.state.displayText, 'にほん');

      ime.toggleScript(); // → katakana (the whole display, not the candidate)
      expect(ime.state.displayText, 'ニホン');
      expect(ime.state.candidates, ['にほん', '日本'],
          reason:
              'candidates are left intact — only the display is re-scripted');
      expect(ime.state.phase, ImePhase.converting); // stays active
      expect(ime.state.preedit, 'にほん'); // raw reading preserved

      ime.toggleScript(); // self-inverse → back to hiragana
      expect(ime.state.displayText, 'にほん');
      expect(ime.state.candidates, ['にほん', '日本']);
    });

    test('Enter terminates the mode, emitting the toggled text', () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space();
      ime.toggleScript(); // → ニホン
      final committed = await ime.commit();
      expect(committed, 'ニホン');
      expect(ime.state.phase, ImePhase.idle);
    });

    test('a toggle-back leaves Space free to re-cycle kanji candidates',
        () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space();
      ime.toggleScript(); // → ニホン
      ime.toggleScript(); // → にほん (restored)
      await ime.space(); // cycle forward to the kanji candidate
      expect(ime.state.candidateIndex, 1);
      expect(ime.state.displayText, '日本');
    });

    test('is a no-op on a kanji candidate (nothing to flip)', () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      await ime.space();
      await ime.space(); // cycle to 日本 (index 1)
      expect(ime.state.displayText, '日本');
      ime.toggleScript(); // kanji has no kana → unchanged
      expect(ime.state.displayText, '日本');
      expect(ime.state.candidateIndex, 1);
    });

    test('is a no-op in idle', () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.toggleScript(); // idle
      expect(ime.state.phase, ImePhase.idle);
      expect(ime.state.displayText, '');
    });

    test('flips the raw kana in place while composing, keeping the reading',
        () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん'); // composing
      expect(ime.state.displayText, 'にほん');

      ime.toggleScript(); // → katakana, shown in place
      expect(ime.state.phase, ImePhase.composing);
      expect(ime.state.displayText, 'ニホン');
      expect(ime.state.preedit, 'にほん',
          reason: 'the reading is preserved so Space can still convert');

      ime.toggleScript(); // self-inverse → back to hiragana
      expect(ime.state.displayText, 'にほん');
    });

    test('a composing flip still lets Space convert the preserved reading',
        () async {
      final ime = ImeController(AnthyEgg(_KanaCandidateAnthy()));
      addTearDown(ime.dispose);

      ime.feedKana('にほん');
      ime.toggleScript(); // ニホン shown, にほん reading kept
      await ime.space(); // converts the preserved reading, not the katakana
      expect(ime.state.phase, ImePhase.converting);
      expect(ime.state.candidates, ['にほん', '日本']);
    });
  });
}
