// Intent registry for the keymap editor.
//
// The keymap editor and the JSON config work in terms of stable string
// *intent ids*, not [Intent] instances (which have no identity across a
// serialise round-trip). [KeymapRegistry] is the bidirectional bridge:
// id → how to (re)construct the [Intent] + how to label it; and [Intent]
// (by runtime type) → id. The kit's own editor intents are preloaded by
// [KeymapRegistry.defaults]; a host app (e.g. voicelab with its kana/IME
// intents) registers additional actions with [register], so its intents
// appear in the editor and round-trip through saved configs.
library;

import 'package:flutter/widgets.dart';

import 'editor_intents.dart';

/// A registered editor action: a stable [id], a human [label], a display
/// [group], and a [factory] that builds the [Intent] (so it can be
/// reconstructed from a persisted id).
@immutable
class KeymapAction {
  /// Create a [KeymapAction].
  const KeymapAction({
    required this.id,
    required this.label,
    required this.group,
    required this.factory,
  });

  /// Stable identifier persisted in the JSON config (e.g. `'killLine'`).
  /// Must be unique within a registry.
  final String id;

  /// Human-readable label shown in the editor (e.g. `'Kill line'`).
  final String label;

  /// Display group / section heading (e.g. `'Kill ring'`).
  final String group;

  /// Builds the [Intent] this action represents. The kit's actions return a
  /// const no-arg intent; hosts may return any [Intent].
  final Intent Function() factory;
}

/// Bidirectional registry mapping intent ids to [KeymapAction]s and [Intent]
/// runtime types back to ids.
///
/// Mutable by design: [KeymapRegistry.defaults] seeds the kit's editor
/// intents, then a host [register]s its own so both appear in one editor.
class KeymapRegistry {
  /// Create an empty registry. Most callers want [KeymapRegistry.defaults].
  KeymapRegistry();

  /// A registry preloaded with the kit's editor intents (motions, kill ring,
  /// mark, editing, case, file, quit, help). Each call returns a fresh,
  /// independently mutable instance.
  factory KeymapRegistry.defaults() {
    final r = KeymapRegistry();
    for (final a in _builtinActions) {
      r.register(a, forType: _builtinType[a.id]);
    }
    return r;
  }

  final Map<String, KeymapAction> _byId = <String, KeymapAction>{};
  final List<String> _order = <String>[];
  final Map<Type, String> _idByType = <Type, String>{};

  /// Register [action]. [forType] pins the [Intent] runtime type used by
  /// [idFor] (reverse lookup); omit it to derive the type from a probe
  /// `action.factory()` call. Re-registering the same [KeymapAction.id]
  /// replaces the prior entry (keeping list order).
  void register(KeymapAction action, {Type? forType}) {
    final isNew = !_byId.containsKey(action.id);
    _byId[action.id] = action;
    if (isNew) _order.add(action.id);
    final type = forType ?? action.factory().runtimeType;
    _idByType[type] = action.id;
  }

  /// The registered action for [id], or `null`.
  KeymapAction? action(String id) => _byId[id];

  /// Build the [Intent] for [id], or `null` if unregistered.
  Intent? intentFor(String id) => _byId[id]?.factory();

  /// The id for an [Intent], matched by runtime type, or `null` if that intent
  /// type is not registered. Used to derive a [config] from the default keymap.
  String? idFor(Intent intent) => _idByType[intent.runtimeType];

  /// All registered actions, in registration order.
  List<KeymapAction> get actions => [for (final id in _order) _byId[id]!];

  /// Registered actions grouped by [KeymapAction.group], groups in first-seen
  /// order, actions within a group in registration order.
  Map<String, List<KeymapAction>> get grouped {
    final out = <String, List<KeymapAction>>{};
    for (final id in _order) {
      final a = _byId[id]!;
      (out[a.group] ??= <KeymapAction>[]).add(a);
    }
    return out;
  }

  /// Whether [id] is registered.
  bool contains(String id) => _byId.containsKey(id);
}

// --- the kit's built-in editor intents -------------------------------------
//
// Ids are stable and persisted; do not rename without a migration. Each entry
// pins its Intent runtime type for the reverse ([idFor]) lookup so a default
// keymap can be inverted into a config without instantiating every intent.

const List<KeymapAction> _builtinActions = <KeymapAction>[
  // Motions.
  KeymapAction(
      id: 'moveLineStart',
      label: 'Move to line start',
      group: 'Motions',
      factory: MoveLineStartIntent.new),
  KeymapAction(
      id: 'moveLineEnd',
      label: 'Move to line end',
      group: 'Motions',
      factory: MoveLineEndIntent.new),
  KeymapAction(
      id: 'moveForwardChar',
      label: 'Move forward character',
      group: 'Motions',
      factory: MoveForwardCharIntent.new),
  KeymapAction(
      id: 'moveBackwardChar',
      label: 'Move backward character',
      group: 'Motions',
      factory: MoveBackwardCharIntent.new),
  KeymapAction(
      id: 'moveNextLine',
      label: 'Move to next line',
      group: 'Motions',
      factory: MoveNextLineIntent.new),
  KeymapAction(
      id: 'movePreviousLine',
      label: 'Move to previous line',
      group: 'Motions',
      factory: MovePreviousLineIntent.new),
  KeymapAction(
      id: 'moveForwardWord',
      label: 'Move forward word',
      group: 'Motions',
      factory: MoveForwardWordIntent.new),
  KeymapAction(
      id: 'moveBackwardWord',
      label: 'Move backward word',
      group: 'Motions',
      factory: MoveBackwardWordIntent.new),
  KeymapAction(
      id: 'moveBufferStart',
      label: 'Move to buffer start',
      group: 'Motions',
      factory: MoveBufferStartIntent.new),
  KeymapAction(
      id: 'moveBufferEnd',
      label: 'Move to buffer end',
      group: 'Motions',
      factory: MoveBufferEndIntent.new),
  // Kill ring.
  KeymapAction(
      id: 'killLine',
      label: 'Kill line',
      group: 'Kill ring',
      factory: KillLineIntent.new),
  KeymapAction(
      id: 'killWholeLine',
      label: 'Kill whole line',
      group: 'Kill ring',
      factory: KillWholeLineIntent.new),
  KeymapAction(
      id: 'killRegion',
      label: 'Kill region',
      group: 'Kill ring',
      factory: KillRegionIntent.new),
  KeymapAction(
      id: 'copyRegion',
      label: 'Copy region',
      group: 'Kill ring',
      factory: CopyRegionIntent.new),
  KeymapAction(
      id: 'deleteChar',
      label: 'Delete character',
      group: 'Kill ring',
      factory: DeleteCharIntent.new),
  KeymapAction(
      id: 'deleteWordForward',
      label: 'Delete word forward',
      group: 'Kill ring',
      factory: DeleteWordForwardIntent.new),
  KeymapAction(
      id: 'deleteWordBackward',
      label: 'Delete word backward',
      group: 'Kill ring',
      factory: DeleteWordBackwardIntent.new),
  KeymapAction(
      id: 'yank', label: 'Yank', group: 'Kill ring', factory: YankIntent.new),
  KeymapAction(
      id: 'yankPop',
      label: 'Yank pop',
      group: 'Kill ring',
      factory: YankPopIntent.new),
  KeymapAction(
      id: 'browseKillRing',
      label: 'Browse kill ring',
      group: 'Kill ring',
      factory: BrowseKillRingIntent.new),
  // Mark.
  KeymapAction(
      id: 'setMark',
      label: 'Set mark',
      group: 'Mark',
      factory: SetMarkIntent.new),
  KeymapAction(
      id: 'exchangePointAndMark',
      label: 'Exchange point and mark',
      group: 'Mark',
      factory: ExchangePointAndMarkIntent.new),
  KeymapAction(
      id: 'markWholeBuffer',
      label: 'Mark whole buffer',
      group: 'Mark',
      factory: MarkWholeBufferIntent.new),
  KeymapAction(
      id: 'markPage',
      label: 'Mark page',
      group: 'Mark',
      factory: MarkPageIntent.new),
  // Editing.
  KeymapAction(
      id: 'undo',
      label: 'Undo',
      group: 'Editing',
      factory: EditorUndoIntent.new),
  KeymapAction(
      id: 'redo',
      label: 'Redo',
      group: 'Editing',
      factory: EditorRedoIntent.new),
  KeymapAction(
      id: 'openLine',
      label: 'Open line',
      group: 'Editing',
      factory: OpenLineIntent.new),
  KeymapAction(
      id: 'transposeChars',
      label: 'Transpose characters',
      group: 'Editing',
      factory: TransposeCharsIntent.new),
  KeymapAction(
      id: 'justOneSpace',
      label: 'Just one space',
      group: 'Editing',
      factory: JustOneSpaceIntent.new),
  KeymapAction(
      id: 'deleteHorizontalSpace',
      label: 'Delete horizontal space',
      group: 'Editing',
      factory: DeleteHorizontalSpaceIntent.new),
  KeymapAction(
      id: 'recenter',
      label: 'Recenter',
      group: 'Editing',
      factory: RecenterIntent.new),
  // Terminal / whitespace translations (historical tty control codes).
  KeymapAction(
      id: 'newline',
      label: 'Newline',
      group: 'Editing',
      factory: NewlineIntent.new),
  KeymapAction(
      id: 'insertTab',
      label: 'Insert tab',
      group: 'Editing',
      factory: InsertTabIntent.new),
  // Case.
  KeymapAction(
      id: 'upcaseWord',
      label: 'Upcase word',
      group: 'Case',
      factory: UpcaseWordIntent.new),
  KeymapAction(
      id: 'downcaseWord',
      label: 'Downcase word',
      group: 'Case',
      factory: DowncaseWordIntent.new),
  KeymapAction(
      id: 'capitalizeWord',
      label: 'Capitalize word',
      group: 'Case',
      factory: CapitalizeWordIntent.new),
  // File / prefix.
  KeymapAction(
      id: 'prefixCtrlX',
      label: 'C-x prefix',
      group: 'File',
      factory: PrefixCtrlXIntent.new),
  KeymapAction(
      id: 'save',
      label: 'Save buffer',
      group: 'File',
      factory: SaveBufferIntent.new),
  KeymapAction(
      id: 'openFile',
      label: 'Open file',
      group: 'File',
      factory: OpenFileIntent.new),
  KeymapAction(
      id: 'writeFile',
      label: 'Write file (save as)',
      group: 'File',
      factory: WriteFileIntent.new),
  KeymapAction(
      id: 'dired',
      label: 'Dired (C-x d)',
      group: 'File',
      factory: DiredIntent.new),
  // Buffers (C-x prefix sequences).
  KeymapAction(
      id: 'switchBuffer',
      label: 'Switch buffer',
      group: 'Buffers',
      factory: SwitchBufferIntent.new),
  KeymapAction(
      id: 'killBuffer',
      label: 'Kill buffer',
      group: 'Buffers',
      factory: KillBufferIntent.new),
  // Quit.
  KeymapAction(
      id: 'keyboardQuit',
      label: 'Keyboard quit',
      group: 'Quit',
      factory: KeyboardQuitIntent.new),
  KeymapAction(
      id: 'saveBuffersKillTerminal',
      label: 'Save buffers and exit (C-x C-c)',
      group: 'Quit',
      factory: SaveBuffersKillTerminalIntent.new),
  // Help.
  KeymapAction(
      id: 'help', label: 'Help', group: 'Help', factory: HelpIntent.new),
  KeymapAction(
      id: 'describeKey',
      label: 'Describe key',
      group: 'Help',
      factory: DescribeKeyIntent.new),
  // Search / replace.
  KeymapAction(
      id: 'isearchForward',
      label: 'Isearch forward',
      group: 'Search',
      factory: IsearchForwardIntent.new),
  KeymapAction(
      id: 'isearchBackward',
      label: 'Isearch backward',
      group: 'Search',
      factory: IsearchBackwardIntent.new),
  KeymapAction(
      id: 'isearchForwardRegexp',
      label: 'Isearch forward regexp',
      group: 'Search',
      factory: IsearchForwardRegexpIntent.new),
  KeymapAction(
      id: 'isearchBackwardRegexp',
      label: 'Isearch backward regexp',
      group: 'Search',
      factory: IsearchBackwardRegexpIntent.new),
  KeymapAction(
      id: 'queryReplace',
      label: 'Query replace',
      group: 'Search',
      factory: QueryReplaceIntent.new),
  KeymapAction(
      id: 'queryReplaceRegexp',
      label: 'Query replace regexp',
      group: 'Search',
      factory: QueryReplaceRegexpIntent.new),
  KeymapAction(
      id: 'occur', label: 'Occur', group: 'Search', factory: OccurIntent.new),
  KeymapAction(
      id: 'swiper',
      label: 'Swiper (live line search)',
      group: 'Search',
      factory: SwiperIntent.new),
  // Commands (extended).
  KeymapAction(
      id: 'executeExtendedCommand',
      label: 'Execute extended command (M-x)',
      group: 'Commands',
      factory: ExecuteExtendedCommandIntent.new),
  KeymapAction(
      id: 'shellCommand',
      label: 'Shell command (M-!)',
      group: 'Commands',
      factory: ShellCommandIntent.new),
  KeymapAction(
      id: 'evalExpression',
      label: 'Eval expression (M-:)',
      group: 'Commands',
      factory: EvalExpressionIntent.new),
  KeymapAction(
      id: 'shell',
      label: 'Shell (M-x shell)',
      group: 'Commands',
      factory: ShellIntent.new),
  // Editing (extended).
  KeymapAction(
      id: 'universalArgument',
      label: 'Universal argument',
      group: 'Editing',
      factory: UniversalArgumentIntent.new),
  KeymapAction(
      id: 'commentDwim',
      label: 'Comment dwim',
      group: 'Editing',
      factory: CommentDwimIntent.new),
  KeymapAction(
      id: 'fillParagraph',
      label: 'Fill paragraph',
      group: 'Editing',
      factory: FillParagraphIntent.new),
  KeymapAction(
      id: 'zapToChar',
      label: 'Zap to char',
      group: 'Editing',
      factory: ZapToCharIntent.new),
  KeymapAction(
      id: 'transposeWords',
      label: 'Transpose words',
      group: 'Editing',
      factory: TransposeWordsIntent.new),
  KeymapAction(
      id: 'transposeLines',
      label: 'Transpose lines',
      group: 'Editing',
      factory: TransposeLinesIntent.new),
  // Registers.
  KeymapAction(
      id: 'copyToRegister',
      label: 'Copy to register',
      group: 'Registers',
      factory: CopyToRegisterIntent.new),
  KeymapAction(
      id: 'insertRegister',
      label: 'Insert register',
      group: 'Registers',
      factory: InsertRegisterIntent.new),
  // Macros.
  KeymapAction(
      id: 'startMacro',
      label: 'Start macro',
      group: 'Macros',
      factory: StartMacroIntent.new),
  KeymapAction(
      id: 'endMacro',
      label: 'End macro',
      group: 'Macros',
      factory: EndMacroIntent.new),
  KeymapAction(
      id: 'callMacro',
      label: 'Call macro',
      group: 'Macros',
      factory: CallMacroIntent.new),
  // Rectangles.
  KeymapAction(
      id: 'killRectangle',
      label: 'Kill rectangle',
      group: 'Rectangles',
      factory: KillRectangleIntent.new),
  KeymapAction(
      id: 'yankRectangle',
      label: 'Yank rectangle',
      group: 'Rectangles',
      factory: YankRectangleIntent.new),
  // Navigation (extended).
  KeymapAction(
      id: 'gotoLine',
      label: 'Goto line',
      group: 'Navigation',
      factory: GotoLineIntent.new),
  KeymapAction(
      id: 'scrollUp',
      label: 'Scroll up',
      group: 'Navigation',
      factory: ScrollUpIntent.new),
  KeymapAction(
      id: 'scrollDown',
      label: 'Scroll down',
      group: 'Navigation',
      factory: ScrollDownIntent.new),
  // Buffers (extended).
  KeymapAction(
      id: 'listBuffers',
      label: 'List buffers',
      group: 'Buffers',
      factory: ListBuffersIntent.new),
  KeymapAction(
      id: 'nextBuffer',
      label: 'Next buffer',
      group: 'Buffers',
      factory: NextBufferIntent.new),
  KeymapAction(
      id: 'previousBuffer',
      label: 'Previous buffer',
      group: 'Buffers',
      factory: PreviousBufferIntent.new),
  // Help (extended).
  KeymapAction(
      id: 'describeBindings',
      label: 'Describe bindings',
      group: 'Help',
      factory: DescribeBindingsIntent.new),
  KeymapAction(
      id: 'whereIs',
      label: 'Where is',
      group: 'Help',
      factory: WhereIsIntent.new),
  KeymapAction(
      id: 'aproposCommand',
      label: 'Apropos command',
      group: 'Help',
      factory: AproposCommandIntent.new),
  // Org structure editing.
  KeymapAction(
      id: 'todoCycle',
      label: 'TODO cycle',
      group: 'Org',
      factory: TodoCycleIntent.new),
  KeymapAction(
      id: 'babelExecute',
      label: 'Execute source block',
      group: 'Org',
      factory: BabelExecuteIntent.new),
  // Windows.
  KeymapAction(
      id: 'splitWindowBelow',
      label: 'Split window below',
      group: 'Windows',
      factory: SplitWindowBelowIntent.new),
  KeymapAction(
      id: 'splitWindowRight',
      label: 'Split window right',
      group: 'Windows',
      factory: SplitWindowRightIntent.new),
  KeymapAction(
      id: 'deleteWindow',
      label: 'Delete window',
      group: 'Windows',
      factory: DeleteWindowIntent.new),
  KeymapAction(
      id: 'deleteOtherWindows',
      label: 'Delete other windows',
      group: 'Windows',
      factory: DeleteOtherWindowsIntent.new),
  KeymapAction(
      id: 'otherWindow',
      label: 'Other window',
      group: 'Windows',
      factory: OtherWindowIntent.new),
  // Narrowing / imenu.
  KeymapAction(
      id: 'narrowToSubtree',
      label: 'Narrow to subtree (C-x n s)',
      group: 'Narrowing',
      factory: NarrowToSubtreeIntent.new),
  KeymapAction(
      id: 'widen',
      label: 'Widen (C-x n w)',
      group: 'Narrowing',
      factory: WidenIntent.new),
  KeymapAction(
      id: 'imenu',
      label: 'Imenu (M-g i)',
      group: 'Narrowing',
      factory: ImenuIntent.new),
];

/// Pin each built-in id to its [Intent] runtime type so [idFor] works without
/// instantiating a probe. (Kept in sync with [_builtinActions].)
const Map<String, Type> _builtinType = <String, Type>{
  'moveLineStart': MoveLineStartIntent,
  'moveLineEnd': MoveLineEndIntent,
  'moveForwardChar': MoveForwardCharIntent,
  'moveBackwardChar': MoveBackwardCharIntent,
  'moveNextLine': MoveNextLineIntent,
  'movePreviousLine': MovePreviousLineIntent,
  'moveForwardWord': MoveForwardWordIntent,
  'moveBackwardWord': MoveBackwardWordIntent,
  'moveBufferStart': MoveBufferStartIntent,
  'moveBufferEnd': MoveBufferEndIntent,
  'killLine': KillLineIntent,
  'killWholeLine': KillWholeLineIntent,
  'killRegion': KillRegionIntent,
  'copyRegion': CopyRegionIntent,
  'deleteChar': DeleteCharIntent,
  'deleteWordForward': DeleteWordForwardIntent,
  'deleteWordBackward': DeleteWordBackwardIntent,
  'yank': YankIntent,
  'yankPop': YankPopIntent,
  'browseKillRing': BrowseKillRingIntent,
  'setMark': SetMarkIntent,
  'exchangePointAndMark': ExchangePointAndMarkIntent,
  'markWholeBuffer': MarkWholeBufferIntent,
  'markPage': MarkPageIntent,
  'undo': EditorUndoIntent,
  'redo': EditorRedoIntent,
  'openLine': OpenLineIntent,
  'transposeChars': TransposeCharsIntent,
  'justOneSpace': JustOneSpaceIntent,
  'deleteHorizontalSpace': DeleteHorizontalSpaceIntent,
  'recenter': RecenterIntent,
  'newline': NewlineIntent,
  'insertTab': InsertTabIntent,
  'upcaseWord': UpcaseWordIntent,
  'downcaseWord': DowncaseWordIntent,
  'capitalizeWord': CapitalizeWordIntent,
  'prefixCtrlX': PrefixCtrlXIntent,
  'save': SaveBufferIntent,
  'openFile': OpenFileIntent,
  'writeFile': WriteFileIntent,
  'dired': DiredIntent,
  'switchBuffer': SwitchBufferIntent,
  'killBuffer': KillBufferIntent,
  'keyboardQuit': KeyboardQuitIntent,
  'saveBuffersKillTerminal': SaveBuffersKillTerminalIntent,
  'help': HelpIntent,
  'describeKey': DescribeKeyIntent,
  'isearchForward': IsearchForwardIntent,
  'isearchBackward': IsearchBackwardIntent,
  'isearchForwardRegexp': IsearchForwardRegexpIntent,
  'isearchBackwardRegexp': IsearchBackwardRegexpIntent,
  'queryReplace': QueryReplaceIntent,
  'queryReplaceRegexp': QueryReplaceRegexpIntent,
  'occur': OccurIntent,
  'swiper': SwiperIntent,
  'executeExtendedCommand': ExecuteExtendedCommandIntent,
  'shellCommand': ShellCommandIntent,
  'evalExpression': EvalExpressionIntent,
  'shell': ShellIntent,
  'universalArgument': UniversalArgumentIntent,
  'commentDwim': CommentDwimIntent,
  'fillParagraph': FillParagraphIntent,
  'zapToChar': ZapToCharIntent,
  'transposeWords': TransposeWordsIntent,
  'transposeLines': TransposeLinesIntent,
  'copyToRegister': CopyToRegisterIntent,
  'insertRegister': InsertRegisterIntent,
  'startMacro': StartMacroIntent,
  'endMacro': EndMacroIntent,
  'callMacro': CallMacroIntent,
  'killRectangle': KillRectangleIntent,
  'yankRectangle': YankRectangleIntent,
  'gotoLine': GotoLineIntent,
  'scrollUp': ScrollUpIntent,
  'scrollDown': ScrollDownIntent,
  'listBuffers': ListBuffersIntent,
  'nextBuffer': NextBufferIntent,
  'previousBuffer': PreviousBufferIntent,
  'describeBindings': DescribeBindingsIntent,
  'whereIs': WhereIsIntent,
  'aproposCommand': AproposCommandIntent,
  'todoCycle': TodoCycleIntent,
  'babelExecute': BabelExecuteIntent,
  'splitWindowBelow': SplitWindowBelowIntent,
  'splitWindowRight': SplitWindowRightIntent,
  'deleteWindow': DeleteWindowIntent,
  'deleteOtherWindows': DeleteOtherWindowsIntent,
  'otherWindow': OtherWindowIntent,
  'narrowToSubtree': NarrowToSubtreeIntent,
  'widen': WidenIntent,
  'imenu': ImenuIntent,
};
