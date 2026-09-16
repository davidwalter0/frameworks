// The presentation picker: a menu button whose face is the current app-wide
// settings presentation's icon. Lifted from textloom's chrome
// (lib/chrome/settings_presentation_menu_button.dart), where it sits beside the
// settings gear; generalised with [SettingsPresentationMenuButton.options] (textloom
// offers only the sliding sheet and the two spans) and an optional controller.
library;

import 'package:flutter/material.dart';

import 'settings_presentation.dart';

/// A [MenuAnchor]-backed icon button for choosing, app-wide, how settings
/// surface. Its face IS the [current] presentation's icon and its tooltip
/// names it, so the button doubles as an always-visible readout; the menu
/// lists [options] with a check on [current].
///
/// Keys: the button is `Key('settingsPresentationMenu.button')`, each item
/// `Key('settingsPresentationMenu.<name>')`.
///
/// [labelOf] and [iconOf] let a host name a presentation in its own terms —
/// zplay calls [SettingsPresentation.inline] its "Side panel" — while every
/// other host keeps the kit's names.
class SettingsPresentationMenuButton extends StatefulWidget {
  /// Creates the picker.
  const SettingsPresentationMenuButton({
    super.key,
    required this.current,
    required this.onSelected,
    this.options = SettingsPresentation.values,
    this.controller,
    this.axis = Axis.horizontal,
    this.labelOf,
    this.iconOf,
  });

  /// The active presentation (the face icon, the checked item).
  final SettingsPresentation current;

  /// Called with the chosen presentation.
  final ValueChanged<SettingsPresentation> onSelected;

  /// The presentations offered, in menu order.
  final List<SettingsPresentation> options;

  /// Supplied by a host that needs to know whether the menu is open — an
  /// Escape handler closing one layer per press, as in textloom's shell; an
  /// internal controller is used otherwise.
  final MenuController? controller;

  /// The placement's axis: in a vertical rail the menu opens beside the
  /// button rather than over it.
  final Axis axis;

  /// The name shown for a presentation, in the menu and the tooltip;
  /// [SettingsPresentation.label] when null.
  final String Function(SettingsPresentation mode)? labelOf;

  /// The icon shown for a presentation, on the face and in the menu;
  /// [SettingsPresentation.icon] when null.
  final IconData Function(SettingsPresentation mode)? iconOf;

  @override
  State<SettingsPresentationMenuButton> createState() =>
      _SettingsPresentationMenuButtonState();
}

class _SettingsPresentationMenuButtonState
    extends State<SettingsPresentationMenuButton> {
  final MenuController _own = MenuController();

  @override
  Widget build(BuildContext context) {
    final SettingsPresentation current = widget.current;
    String label(SettingsPresentation mode) =>
        widget.labelOf?.call(mode) ?? mode.label;
    IconData icon(SettingsPresentation mode) =>
        widget.iconOf?.call(mode) ?? mode.icon;
    return MenuAnchor(
      controller: widget.controller ?? _own,
      alignmentOffset:
          widget.axis == Axis.horizontal ? Offset.zero : const Offset(8, 0),
      menuChildren: <Widget>[
        for (final SettingsPresentation mode in widget.options)
          MenuItemButton(
            key: Key('settingsPresentationMenu.${mode.name}'),
            leadingIcon: Icon(icon(mode)),
            trailingIcon: mode == current ? const Icon(Icons.check) : null,
            onPressed: () => widget.onSelected(mode),
            child: Text(label(mode)),
          ),
      ],
      builder: (BuildContext context, MenuController menu, Widget? _) =>
          IconButton(
        key: const Key('settingsPresentationMenu.button'),
        tooltip: 'Settings presentation: ${label(current)}',
        icon: Icon(icon(current)),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }
}
