// Typing a new character while a conversion is on screen must never DESTROY
// the character.
//
// Every mainstream Japanese IME (ibus-anthy, mozc, the Windows and macOS IMEs)
// treats a letter typed during the converting phase as "the user has accepted
// this conversion and moved on": the conversion commits and a fresh composition
// begins with the new character. What must never happen is the character being
// consumed by the input path and then thrown away — the user sees a keystroke
// register and produce nothing.
//
// Regression origin: `ImeController.feedKana` returned early while converting,
// so `PreeditSession.feed`/`feedKana` reported the character CONSUMED (the host
// therefore did not insert it itself) while the controller discarded it.
// Symptom in the field: long phrases lost characters and converted in pieces —
// お誕生日おめでとうございます came out as a concatenation of several unrelated
// independent conversions with kana missing between them.
import 'dart:async';

import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted fake `anthy-agent --egg`.
///
/// Converts by reading — each supported reading maps to its own single-segment
/// result — so a test can tell WHICH reading reached the agent, not merely that
/// some conversion happened. An unknown reading converts to a marker rather
/// than erroring, so a wrong-reading failure reports the reading it saw.
class _ScriptedAnthy implements AnthyProcess {
  late final StreamController<String> _out = StreamController<String>.broadcast(
    onListen: () => scheduleMicrotask(
      () => _emit('Anthy (Version fake) [] : Nice to meet you.'),
    ),
  );

  /// Readings this fake knows, and the kanji each converts to.
  static const Map<String, String> _table = <String, String>{
    'にほん': '日本',
    'ご': '語',
    'にほんご': '日本語',
  };

  /// Every CONVERT reading the agent was asked for, in order — the assertion
  /// surface for "was the whole phrase converted once, or in pieces?".
  final List<String> converted = <String>[];

  void _emit(String line) {
    if (!_out.isClosed) _out.add(line);
  }

  @override
  Stream<String> get lines => _out.stream;

  @override
  void send(String line) {
    final List<String> parts = line.split(' ');
    List<String> resp;
    switch (parts.first) {
      case 'NEW-CONTEXT':
        resp = <String>['+OK 1'];
      case 'CONVERT':
        final String reading = parts.sublist(2).join(' ');
        converted.add(reading);
        final String best = _table[reading] ?? '?$reading?';
        resp = <String>['+DATA 0 0 1', '1 $best $reading', ''];
      case 'GET-CANDIDATES':
        resp = <String>['+DATA 1 1', _lastBest, ''];
      case 'SELECT-CANDIDATE' || 'COMMIT' || 'RELEASE-CONTEXT':
        resp = <String>['+OK'];
      default:
        resp = <String>['-ERR unexpected: $line'];
    }
    scheduleMicrotask(() => resp.forEach(_emit));
  }

  String get _lastBest => converted.isEmpty
      ? ''
      : (_table[converted.last] ?? '?${converted.last}?');

  @override
  Future<void> kill() async {
    if (!_out.isClosed) await _out.close();
  }
}

/// Minimal [PreeditHost] over a mutable (text, caret) — same splice semantics
/// as `EmacsBuffer.replaceBeforeCaret`.
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
  group('typing while converting must not destroy input', () {
    test('kana typed during the converting phase reaches the document',
        () async {
      final _FakeHost host = _FakeHost();
      final _ScriptedAnthy agent = _ScriptedAnthy();
      final PreeditSession s = PreeditSession.overEgg(host, AnthyEgg(agent));
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space(); // にほん → 日本, now converting
      expect(s.state.phase, PreeditPhase.converting,
          reason: 'precondition: the conversion is on screen');
      expect(host.text, '日本');

      // The user types on. Whatever the policy for the conversion itself, the
      // ご MUST survive: it was accepted by the input path.
      s.feedKana('ご');
      await Future<void>.delayed(Duration.zero);

      expect(host.text, contains('ご'),
          reason: 'ご was consumed by the IME and then silently discarded — '
              'the keystroke produced nothing at all');
    });

    test('the conversion commits and a NEW composition starts', () async {
      final _FakeHost host = _FakeHost();
      final _ScriptedAnthy agent = _ScriptedAnthy();
      final PreeditSession s = PreeditSession.overEgg(host, AnthyEgg(agent));
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space();
      s.feedKana('ご');
      await Future<void>.delayed(Duration.zero);

      expect(host.text, '日本ご',
          reason: 'the accepted conversion is finalised and ご begins a fresh '
              'composing run beside it');
      expect(s.state.phase, PreeditPhase.composing,
          reason: 'typing leaves the converting phase — further Space must '
              'convert the NEW run, not cycle the old conversion');
      expect(s.state.region.text, 'ご',
          reason: 'the live region covers only the new run; 日本 is committed');
    });

    test('Space after typing converts only the new run, not the whole line',
        () async {
      final _FakeHost host = _FakeHost();
      final _ScriptedAnthy agent = _ScriptedAnthy();
      final PreeditSession s = PreeditSession.overEgg(host, AnthyEgg(agent));
      addTearDown(s.dispose);

      s.feedKana('にほん');
      await s.space();
      s.feedKana('ご');
      await Future<void>.delayed(Duration.zero);
      await s.space();

      expect(agent.converted, <String>['にほん', 'ご'],
          reason: 'each run is converted once, with its own reading');
      expect(host.text, '日本語');
    });
  });
}
