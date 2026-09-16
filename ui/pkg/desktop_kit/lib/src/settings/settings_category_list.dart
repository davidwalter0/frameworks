// The settings category LIST: one single-line row per category, the root of
// the settings "stack" in every presentation.
//
// Lifted from textloom, whose settings open as a stack of sheets: a root sheet
// listing every category (lib/main.dart `openSettingsSheetStack` /
// `_SettingsSheetRoot`), each row opening its category on top. Generalised so
// a host gets the same list whichever way it surfaces settings:
//   • popup / sliding sheet — [openSettingsCategoryList] opens the list as a
//     route, and each row opens its category on top of it via
//     [openSettingsCategory]; the pages stack and Escape pops one at a time.
//   • inline / top span / bottom span — regions the host lays out, not routes:
//     [SettingsCategoryNavigator] shows the list and opens a row's page in
//     place, with a back arrow.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings_presentation.dart';

/// One single-line row per [SettingsCategory] — its icon, its title and a
/// chevron — tapping a row calls [onOpen] with that category.
///
/// [header] rows render above the categories: app-level controls that belong
/// in settings but in no one category (textloom's navigation-style / keymap /
/// input-method selectors).
///
/// Row keys are `ValueKey('settingsCategoryList.<id>')` in every host.
///
/// Not scrollable itself: the host provides the scroll view, within its own
/// axis budget (a sheet's [DraggableScrollableSheet], a dialog body, a docked
/// panel).
class SettingsCategoryList extends StatelessWidget {
  /// Creates the list.
  const SettingsCategoryList({
    super.key,
    required this.categories,
    required this.onOpen,
    this.header = const <Widget>[],
  });

  /// The categories, in display order.
  final List<SettingsCategory> categories;

  /// Called with the category whose row was tapped.
  final ValueChanged<SettingsCategory> onOpen;

  /// Rows above the categories.
  final List<Widget> header;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ...header,
        for (final SettingsCategory category in categories)
          ListTile(
            key: ValueKey<String>('settingsCategoryList.${category.id}'),
            leading: Icon(category.icon),
            title: Text(category.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(category),
          ),
      ],
    );
  }
}

/// Opens the settings category LIST as a route in [mode], each row opening
/// its category ON TOP of the list — the "stack of sheets" model of
/// [openSettingsCategory], rooted at a list rather than one category. Escape
/// (or Back) pops the top layer, revealing the one beneath.
///
/// - [SettingsPresentation.bottomSheet] → a sliding sheet (drag handle, a
///   [DraggableScrollableSheet] sized by [size]) titled [title].
/// - [SettingsPresentation.popup] → a dialog titled [title], with a close
///   action.
/// - [SettingsPresentation.inline] and the two span modes → a no-op, as for
///   [openSettingsCategory]: those are regions the host lays out, not routes.
///   Render a [SettingsCategoryNavigator] in them instead.
///
/// A row opens its category in [presentationFor]'s answer (default: [mode]).
/// When that is a span mode and [onPinSpan] is given, the list closes and
/// [onPinSpan] runs with the category and the span mode, so the host can
/// mount its span (textloom's per-category span pins). Otherwise a span or
/// inline answer opens the category in [mode], which is always a route.
///
/// Returns when the list itself is dismissed.
Future<void> openSettingsCategoryList(
  BuildContext context,
  List<SettingsCategory> categories,
  SettingsPresentation mode, {
  String title = 'Settings',
  List<Widget> header = const <Widget>[],
  SettingsPanelSize size = const SettingsPanelSize(),
  SettingsPresentation Function(SettingsCategory category)? presentationFor,
  void Function(SettingsCategory category, SettingsPresentation span)?
      onPinSpan,
}) async {
  void open(BuildContext listContext, SettingsCategory category) {
    final SettingsPresentation wanted = presentationFor?.call(category) ?? mode;
    final bool span = wanted == SettingsPresentation.topSpan ||
        wanted == SettingsPresentation.bottomSpan;
    if (span && onPinSpan != null) {
      Navigator.of(listContext).pop();
      onPinSpan(category, wanted);
      return;
    }
    final bool routable = wanted == SettingsPresentation.popup ||
        wanted == SettingsPresentation.bottomSheet;
    openSettingsCategory(listContext, category, routable ? wanted : mode);
  }

  switch (mode) {
    case SettingsPresentation.inline:
    case SettingsPresentation.topSpan:
    case SettingsPresentation.bottomSpan:
      return;
    case SettingsPresentation.popup:
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(title),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: size.popupMaxHeight ?? double.infinity,
            ),
            child: SingleChildScrollView(
              child: SizedBox(
                width: size.popupWidth,
                child: SettingsCategoryList(
                  categories: categories,
                  header: header,
                  onOpen: (SettingsCategory c) => open(ctx, c),
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    case SettingsPresentation.bottomSheet:
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        // EscapeToPop, like every sheet openSettingsCategory opens, so the
        // list and the pages stacked on it handle Escape identically. (A modal
        // sheet also dismisses on Escape through the default DismissIntent:
        // with this wrapper removed the stack's Escape test still passes.)
        builder: (BuildContext ctx) => EscapeToPop(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: size.sheetInitialSize,
            minChildSize: size.sheetMinSize,
            maxChildSize: size.sheetMaxSize,
            builder: (BuildContext ctx2, ScrollController sc) => ListView(
              controller: sc,
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    title,
                    style: Theme.of(ctx2).textTheme.titleLarge,
                  ),
                ),
                SettingsCategoryList(
                  categories: categories,
                  header: header,
                  onOpen: (SettingsCategory c) => open(ctx2, c),
                ),
              ],
            ),
          ),
        ),
      );
      return;
  }
}

/// The category list for a region that is NOT a route — a docked side panel,
/// a pinned span. A row shows its category's page in place, under a back
/// arrow and the category's title; back returns to the list.
///
/// Escape on an open page goes back ONE layer, to the list, before it can
/// reach whatever closes the host: opening a page moves focus into it (the
/// host's own focus sits above this widget, where a binding here would never
/// see the key), and the page's Escape binding consumes the key. On the list
/// itself nothing is bound, so Escape reaches the host as before.
///
/// Rows keep [SettingsCategoryList]'s keys; the page's back button is
/// `Key('settingsCategoryNavigator.back')`. Not scrollable itself, as for
/// [SettingsCategoryList].
///
/// The page's content spans the full width, as in the full-size popup's body:
/// the horizontal inset belongs to the host, which already pads its region —
/// in a narrow docked panel another 16px from here is width the content
/// needs.
class SettingsCategoryNavigator extends StatefulWidget {
  /// Creates the navigator, showing the list.
  const SettingsCategoryNavigator({
    super.key,
    required this.categories,
    this.header = const <Widget>[],
    this.onPageChanged,
  });

  /// The categories, in display order.
  final List<SettingsCategory> categories;

  /// Rows above the categories on the list.
  final List<Widget> header;

  /// Called with the open category's id, or null on returning to the list.
  final ValueChanged<String?>? onPageChanged;

  @override
  State<SettingsCategoryNavigator> createState() =>
      _SettingsCategoryNavigatorState();
}

class _SettingsCategoryNavigatorState extends State<SettingsCategoryNavigator> {
  final FocusNode _pageFocus = FocusNode(
    debugLabel: 'settingsCategoryNavigator.page',
  );
  String? _openId;

  @override
  void dispose() {
    _pageFocus.dispose();
    super.dispose();
  }

  void _show(String? id) {
    setState(() => _openId = id);
    widget.onPageChanged?.call(id);
    if (id == null) return;
    // Post-frame: the page's Focus must be mounted before it can take focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _openId == id) _pageFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    SettingsCategory? open;
    for (final SettingsCategory c in widget.categories) {
      if (c.id == _openId) open = c;
    }
    final SettingsCategory? page = open;
    if (page == null) {
      return SettingsCategoryList(
        categories: widget.categories,
        header: widget.header,
        onOpen: (SettingsCategory c) => _show(c.id),
      );
    }
    final ThemeData theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () => _show(null),
      },
      child: Focus(
        focusNode: _pageFocus,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  key: const Key('settingsCategoryNavigator.back'),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to Settings',
                  onPressed: () => _show(null),
                ),
                Icon(page.icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(page.title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: page.content(context),
            ),
          ],
        ),
      ),
    );
  }
}
