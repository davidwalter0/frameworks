// Tests for the search/replace, extended-editing, register, macro,
// rectangle, extended-navigation, extended-buffer, and extended-help
// intents added alongside the built-in editor keymap.
import 'package:desktop_kit/desktop_kit_keymap.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('new capability intents are registered', () {
    test('Search group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('isearchForward')!.label, 'Isearch forward');
      expect(reg.action('isearchBackward')!.label, 'Isearch backward');
      expect(reg.action('queryReplace')!.label, 'Query replace');
      expect(reg.action('occur')!.label, 'Occur');
      expect(reg.intentFor('isearchForward'), isA<IsearchForwardIntent>());
      expect(reg.intentFor('isearchBackward'), isA<IsearchBackwardIntent>());
      expect(reg.intentFor('queryReplace'), isA<QueryReplaceIntent>());
      expect(reg.intentFor('occur'), isA<OccurIntent>());
    });

    test('Editing (extended) group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('universalArgument')!.label, 'Universal argument');
      expect(reg.action('commentDwim')!.label, 'Comment dwim');
      expect(reg.action('zapToChar')!.label, 'Zap to char');
      expect(reg.action('transposeWords')!.label, 'Transpose words');
      expect(reg.action('transposeLines')!.label, 'Transpose lines');
      expect(
          reg.intentFor('universalArgument'), isA<UniversalArgumentIntent>());
      expect(reg.intentFor('commentDwim'), isA<CommentDwimIntent>());
      expect(reg.intentFor('zapToChar'), isA<ZapToCharIntent>());
      expect(reg.intentFor('transposeWords'), isA<TransposeWordsIntent>());
      expect(reg.intentFor('transposeLines'), isA<TransposeLinesIntent>());
    });

    test('Registers group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('copyToRegister')!.label, 'Copy to register');
      expect(reg.action('insertRegister')!.label, 'Insert register');
      expect(reg.intentFor('copyToRegister'), isA<CopyToRegisterIntent>());
      expect(reg.intentFor('insertRegister'), isA<InsertRegisterIntent>());
    });

    test('Macros group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('startMacro')!.label, 'Start macro');
      expect(reg.action('endMacro')!.label, 'End macro');
      expect(reg.action('callMacro')!.label, 'Call macro');
      expect(reg.intentFor('startMacro'), isA<StartMacroIntent>());
      expect(reg.intentFor('endMacro'), isA<EndMacroIntent>());
      expect(reg.intentFor('callMacro'), isA<CallMacroIntent>());
    });

    test('Rectangles group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('killRectangle')!.label, 'Kill rectangle');
      expect(reg.action('yankRectangle')!.label, 'Yank rectangle');
      expect(reg.intentFor('killRectangle'), isA<KillRectangleIntent>());
      expect(reg.intentFor('yankRectangle'), isA<YankRectangleIntent>());
    });

    test('Navigation (extended) group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('gotoLine')!.label, 'Goto line');
      expect(reg.action('scrollUp')!.label, 'Scroll up');
      expect(reg.action('scrollDown')!.label, 'Scroll down');
      expect(reg.intentFor('gotoLine'), isA<GotoLineIntent>());
      expect(reg.intentFor('scrollUp'), isA<ScrollUpIntent>());
      expect(reg.intentFor('scrollDown'), isA<ScrollDownIntent>());
    });

    test('Buffers (extended) group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('listBuffers')!.label, 'List buffers');
      expect(reg.action('nextBuffer')!.label, 'Next buffer');
      expect(reg.action('previousBuffer')!.label, 'Previous buffer');
      expect(reg.intentFor('listBuffers'), isA<ListBuffersIntent>());
      expect(reg.intentFor('nextBuffer'), isA<NextBufferIntent>());
      expect(reg.intentFor('previousBuffer'), isA<PreviousBufferIntent>());
    });

    test('Help (extended) group', () {
      final reg = KeymapRegistry.defaults();
      expect(reg.action('describeBindings')!.label, 'Describe bindings');
      expect(reg.action('whereIs')!.label, 'Where is');
      expect(reg.action('aproposCommand')!.label, 'Apropos command');
      expect(reg.intentFor('describeBindings'), isA<DescribeBindingsIntent>());
      expect(reg.intentFor('whereIs'), isA<WhereIsIntent>());
      expect(reg.intentFor('aproposCommand'), isA<AproposCommandIntent>());
    });
  });

  group('default Emacs keymap — new default chords', () {
    test('maps the seven newly-bound default chords to the right intents', () {
      final map = Keymaps.forMode(KeymapMode.emacs);
      final byType = <Type, Intent>{
        for (final intent in map.values) intent.runtimeType: intent,
      };
      expect(byType[IsearchBackwardIntent], isA<IsearchBackwardIntent>());
      expect(byType[UniversalArgumentIntent], isA<UniversalArgumentIntent>());
      expect(byType[ScrollUpIntent], isA<ScrollUpIntent>());
      expect(byType[ScrollDownIntent], isA<ScrollDownIntent>());
      expect(byType[TransposeWordsIntent], isA<TransposeWordsIntent>());
      expect(byType[ZapToCharIntent], isA<ZapToCharIntent>());
      expect(byType[CommentDwimIntent], isA<CommentDwimIntent>());
    });
  });
}
