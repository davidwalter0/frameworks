import 'dart:async';

import 'package:desktop_kit/desktop_kit.dart';
import 'package:desktop_kit/desktop_kit_anthy.dart';
import 'package:desktop_kit/desktop_kit_anthy_keymap.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted fake `anthy-agent --egg` (same fixture as the anthy tests): any
/// hiragana → 1 segment, candidates ['日本', '二本']. Drives a real
/// [ImeController] with no subprocess.
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
      'NEW-CONTEXT' => <String>['+OK 1'],
      'CONVERT' => <String>['+DATA 0 0 1', '2 日本 にほん', ''],
      'GET-CANDIDATES' => <String>['+DATA 1 2', '日本', '二本', ''],
      'SELECT-CANDIDATE' => <String>['+OK'],
      'RESIZE-SEGMENT' => <String>['+DATA 1 0 1', '2 日本 にほん', ''],
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

ImeController _controller() => ImeController(AnthyEgg(_ScriptedAnthy()));

void main() {
  test('registerAnthyActions adds the IME actions, keeping kit built-ins', () {
    final registry = KeymapRegistry.defaults();
    registerAnthyActions(registry);
    for (final String id in kAnthyIntentIds) {
      expect(registry.contains(id), isTrue, reason: id);
      expect(registry.action(id)?.group, 'IME (Anthy)', reason: id);
    }
    expect(registry.contains('killLine'), isTrue);
  });

  test('anthyDefaultBindings maps the egg-convention chords', () {
    final b = anthyDefaultBindings();
    KeyChordSequence seq(LogicalKeyboardKey k, {bool shift = false}) =>
        KeyChordSequence.single(KeyChord(keyId: k.keyId, shift: shift));
    expect(b[seq(LogicalKeyboardKey.space)], kConvertOrNextCandidateId);
    expect(b[seq(LogicalKeyboardKey.space, shift: true)], kPreviousCandidateId);
    expect(b[seq(LogicalKeyboardKey.enter)], kCommitConversionId);
    expect(b[seq(LogicalKeyboardKey.escape)], kCancelConversionId);
    expect(b[seq(LogicalKeyboardKey.backspace)], kImeBackspaceId);
  });

  test('anthyDefaultConfig carries the bindings under every mode', () {
    final config = anthyDefaultConfig();
    for (final KeymapMode mode in KeymapMode.values) {
      expect(config.bindingsFor(mode).length, anthyDefaultBindings().length,
          reason: mode.name);
    }
  });

  test('isAnthyIntentId discriminates IME intents', () {
    expect(isAnthyIntentId(kCommitConversionId), isTrue);
    expect(isAnthyIntentId('moveLineStart'), isFalse);
  });

  test('dispatch drives convert → next → previous → commit', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');

    final r1 = await dispatchAnthyIntent(ime, kConvertOrNextCandidateId);
    expect(r1.handled, isTrue);
    expect(ime.state.phase, ImePhase.converting);
    expect(ime.state.displayText, '日本');

    await dispatchAnthyIntent(ime, kConvertOrNextCandidateId); // next
    expect(ime.state.displayText, '二本');

    await dispatchAnthyIntent(ime, kPreviousCandidateId); // previous
    expect(ime.state.displayText, '日本');

    final rc = await dispatchAnthyIntent(ime, kCommitConversionId);
    expect(rc.committed, '日本');
    expect(rc.cancelled, isNull);
    expect(ime.state.phase, ImePhase.idle);
  });

  test('dispatch cancel reverts to the raw hiragana', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');
    await dispatchAnthyIntent(ime, kConvertOrNextCandidateId);

    final r = await dispatchAnthyIntent(ime, kCancelConversionId);
    expect(r.cancelled, 'にほん');
    expect(r.committed, isNull);
    expect(ime.state.phase, ImePhase.idle);
  });

  test('dispatch IME backspace reverts converting → composing', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');
    await dispatchAnthyIntent(ime, kConvertOrNextCandidateId); // converting
    await dispatchAnthyIntent(ime, kImeBackspaceId);
    expect(ime.state.phase, ImePhase.composing);
    expect(ime.state.preedit, 'にほん');
  });

  test('unknown id is unhandled and leaves the controller untouched', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');
    final r = await dispatchAnthyIntent(ime, 'nope');
    expect(r.handled, isFalse);
    expect(ime.state.phase, ImePhase.composing);
  });

  test('anthyDefaultBindings maps segment nav/resize chords (Phase-2b)', () {
    final b = anthyDefaultBindings();
    KeyChordSequence seq(LogicalKeyboardKey k, {bool shift = false}) =>
        KeyChordSequence.single(KeyChord(keyId: k.keyId, shift: shift));
    expect(b[seq(LogicalKeyboardKey.arrowRight)], kMoveSegmentNextId);
    expect(b[seq(LogicalKeyboardKey.arrowLeft)], kMoveSegmentPreviousId);
    expect(
      b[seq(LogicalKeyboardKey.arrowLeft, shift: true)],
      kShrinkSegmentId,
    );
    expect(
      b[seq(LogicalKeyboardKey.arrowRight, shift: true)],
      kGrowSegmentId,
    );
  });

  test('dispatch moves the active segment (Phase-2b)', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');
    await dispatchAnthyIntent(ime, kConvertOrNextCandidateId);
    expect(ime.state.activeSegment, 0);

    final rNext = await dispatchAnthyIntent(ime, kMoveSegmentNextId);
    expect(rNext.handled, isTrue);
    // Single-segment fixture: no next segment, so the cursor stays put.
    expect(ime.state.activeSegment, 0);

    final rPrev = await dispatchAnthyIntent(ime, kMoveSegmentPreviousId);
    expect(rPrev.handled, isTrue);
    expect(ime.state.activeSegment, 0);
  });

  test('dispatch grow/shrink segment reach the controller (Phase-2b)',
      () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん');
    await dispatchAnthyIntent(ime, kConvertOrNextCandidateId);

    final rGrow = await dispatchAnthyIntent(ime, kGrowSegmentId);
    expect(rGrow.handled, isTrue);
    expect(ime.state.phase, ImePhase.converting);

    final rShrink = await dispatchAnthyIntent(ime, kShrinkSegmentId);
    expect(rShrink.handled, isTrue);
    expect(ime.state.phase, ImePhase.converting);
  });

  test('anthyDefaultBindings maps Shift+K to toggle-script', () {
    final b = anthyDefaultBindings();
    KeyChordSequence seq(LogicalKeyboardKey k, {bool shift = false}) =>
        KeyChordSequence.single(KeyChord(keyId: k.keyId, shift: shift));
    expect(b[seq(LogicalKeyboardKey.keyK, shift: true)], kToggleScriptId);
  });

  test('dispatch toggle-script flips the composing kana in place', () async {
    final ime = _controller();
    addTearDown(ime.dispose);
    ime.feedKana('にほん'); // composing — display is the raw kana

    final r = await dispatchAnthyIntent(ime, kToggleScriptId);
    expect(r.handled, isTrue);
    expect(r.committed, isNull);
    expect(r.cancelled, isNull);
    expect(ime.state.phase, ImePhase.composing);
    expect(ime.state.displayText, 'ニホン');
    expect(ime.state.preedit, 'にほん',
        reason: 'the reading is preserved so Space can still convert');
  });

  group('dispatchPreeditIntent (the PreeditSession twin)', () {
    PreeditSession session(_FakeHost host) =>
        PreeditSession(host, _controller());

    test('convert → next → previous → commit, splicing the host each step',
        () async {
      final host = _FakeHost();
      final s = session(host);
      addTearDown(s.dispose);
      s.feedKana('にほん');
      expect(host.text, 'にほん');

      final r1 = await dispatchPreeditIntent(s, kConvertOrNextCandidateId);
      expect(r1.handled, isTrue);
      expect(r1.outcome, isNull, reason: 'convert is not a terminal intent');
      expect(host.text, '日本', reason: 'the session re-spliced the host');

      await dispatchPreeditIntent(s, kConvertOrNextCandidateId); // next
      expect(host.text, '二本');
      await dispatchPreeditIntent(s, kPreviousCandidateId); // previous
      expect(host.text, '日本');

      final rc = await dispatchPreeditIntent(s, kCommitConversionId);
      expect(rc.outcome?.committed, '日本');
      expect(host.text, '日本');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('cancel is two-stage through the dispatch', () async {
      final host = _FakeHost();
      final s = session(host);
      addTearDown(s.dispose);
      s.feedKana('にほん');
      await dispatchPreeditIntent(s, kConvertOrNextCandidateId);
      expect(host.text, '日本');

      final r1 = await dispatchPreeditIntent(s, kCancelConversionId);
      expect(r1.outcome?.reverted, isNull, reason: 'stage 1 stays composing');
      expect(host.text, 'にほん');
      expect(s.state.phase, PreeditPhase.composing);

      final r2 = await dispatchPreeditIntent(s, kCancelConversionId);
      expect(r2.outcome?.reverted, 'にほん');
      expect(host.text, '');
      expect(s.state.phase, PreeditPhase.idle);
    });

    test('toggle-script flips the composing kana in the host', () async {
      final host = _FakeHost();
      final s = session(host);
      addTearDown(s.dispose);
      s.feedKana('にほん');

      final r = await dispatchPreeditIntent(s, kToggleScriptId);
      expect(r.handled, isTrue);
      expect(host.text, 'ニホン');
      expect(s.state.phase, PreeditPhase.composing);
    });

    test('unknown id is unhandled and leaves the session untouched', () async {
      final host = _FakeHost();
      final s = session(host);
      addTearDown(s.dispose);
      s.feedKana('にほん');

      final r = await dispatchPreeditIntent(s, 'nope');
      expect(r.handled, isFalse);
      expect(host.text, 'にほん');
      expect(s.state.phase, PreeditPhase.composing);
    });
  });
}

/// A [PreeditHost] over a mutable (text, caret) with
/// `EmacsBuffer.replaceBeforeCaret` semantics — enough to prove the dispatch
/// drives the SESSION (and therefore re-splices the host), not a bare controller.
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
