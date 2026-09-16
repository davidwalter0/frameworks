/// A [TextField] that speaks the Linux PRIMARY selection, so every app in the
/// family gets native-desktop clipboard behaviour from one place instead of
/// re-wiring it per field.
///
/// Flutter's built-in [TextField] already handles the CLIPBOARD selection
/// (Ctrl+C / Ctrl+V, the context menu). What it omits — and what this widget
/// adds — is the PRIMARY selection every native Linux app speaks:
///
/// - **highlight → copy**: the current selection is mirrored into PRIMARY
///   (debounced, so a click-drag doesn't spawn a subprocess per intermediate
///   selection), and
/// - **middle-click → paste**: a middle-mouse click inserts the PRIMARY
///   selection at the caret.
///
/// It is a *controlled* widget (per desktop_kit's no-state-management rule):
/// the caller owns the [TextEditingController] and gets [onChanged]. The
/// [PrimarySelection] mechanism is injectable for tests; left null, the widget
/// creates its own, which no-ops off-Linux or when no CLI tool is installed —
/// so `PrimaryTextField` is a safe drop-in replacement for `TextField` on
/// every platform.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'primary_selection.dart';

/// A drop-in [TextField] replacement that participates in the Linux PRIMARY
/// selection (highlight-to-copy + middle-click-to-paste).
///
/// See the library doc for the rationale. Only the commonly-needed [TextField]
/// knobs are forwarded; for anything exotic, compose a raw [TextField] with
/// [middleClickPaste] directly.
class PrimaryTextField extends StatefulWidget {
  /// Creates a PRIMARY-selection-aware text field.
  const PrimaryTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.primary,
    this.decoration,
    this.style,
    this.keyboardType,
    this.textInputAction,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.expands = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.readOnly = false,
    this.enabled,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.enablePrimarySelection = true,
    this.primaryDebounce = const Duration(milliseconds: 150),
  });

  /// The controlling text editing controller (owned by the caller).
  final TextEditingController controller;

  /// Optional focus node; a middle-click paste requests focus on it.
  final FocusNode? focusNode;

  /// The PRIMARY-selection mechanism. Injected in tests; when null the widget
  /// creates its own [PrimarySelection] (which no-ops when unsupported).
  final PrimarySelection? primary;

  /// Field decoration, forwarded to the inner [TextField].
  final InputDecoration? decoration;

  /// Text style, forwarded to the inner [TextField].
  final TextStyle? style;

  /// Keyboard type, forwarded to the inner [TextField].
  final TextInputType? keyboardType;

  /// Keyboard action, forwarded to the inner [TextField].
  final TextInputAction? textInputAction;

  /// Horizontal text alignment, forwarded to the inner [TextField].
  final TextAlign textAlign;

  /// Vertical text alignment, forwarded to the inner [TextField].
  final TextAlignVertical? textAlignVertical;

  /// Whether the field expands to fill its parent, forwarded to [TextField].
  final bool expands;

  /// Maximum lines, forwarded to the inner [TextField] (null = unbounded).
  final int? maxLines;

  /// Minimum lines, forwarded to the inner [TextField].
  final int? minLines;

  /// Maximum length, forwarded to the inner [TextField].
  final int? maxLength;

  /// Whether the field is read-only, forwarded to the inner [TextField].
  final bool readOnly;

  /// Whether the field is enabled, forwarded to the inner [TextField].
  final bool? enabled;

  /// Whether to autofocus, forwarded to the inner [TextField].
  final bool autofocus;

  /// Change callback, forwarded to the inner [TextField].
  final ValueChanged<String>? onChanged;

  /// Submit callback, forwarded to the inner [TextField].
  final ValueChanged<String>? onSubmitted;

  /// When false, the widget is a plain [TextField] passthrough (no PRIMARY
  /// behaviour) — useful for password / sensitive fields.
  final bool enablePrimarySelection;

  /// Debounce before a new selection is written to PRIMARY.
  final Duration primaryDebounce;

  @override
  State<PrimaryTextField> createState() => _PrimaryTextFieldState();
}

class _PrimaryTextFieldState extends State<PrimaryTextField> {
  late PrimarySelection _primary;
  Timer? _debounce;
  String? _lastWritten;

  @override
  void initState() {
    super.initState();
    _primary = widget.primary ?? PrimarySelection();
    if (widget.enablePrimarySelection) {
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void didUpdateWidget(PrimaryTextField old) {
    super.didUpdateWidget(old);
    if (old.primary != widget.primary) {
      _primary = widget.primary ?? PrimarySelection();
    }
    if (old.controller != widget.controller ||
        old.enablePrimarySelection != widget.enablePrimarySelection) {
      old.controller.removeListener(_onChanged);
      if (widget.enablePrimarySelection) {
        widget.controller.addListener(_onChanged);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  // Mirror the highlighted text into PRIMARY, debounced.
  void _onChanged() {
    final s = widget.controller.selection;
    if (!s.isValid || s.isCollapsed) return;
    final sel = s.textInside(widget.controller.text);
    if (sel.isEmpty || sel == _lastWritten) return;
    _debounce?.cancel();
    _debounce = Timer(widget.primaryDebounce, () {
      _lastWritten = sel;
      _primary.write(sel);
    });
  }

  Future<void> _pasteAtCursor() async {
    final text = await _primary.read();
    if (text == null || !mounted) return;
    widget.focusNode?.requestFocus();
    final value = widget.controller.value;
    final sel = value.selection;
    final range = sel.isValid
        ? TextRange(start: sel.start, end: sel.end)
        : TextRange.collapsed(value.text.length);
    final newText = value.text.replaceRange(range.start, range.end, text);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: range.start + text.length),
    );
    widget.onChanged?.call(newText);
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      decoration: widget.decoration,
      style: widget.style,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      textAlign: widget.textAlign,
      textAlignVertical: widget.textAlignVertical,
      expands: widget.expands,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      maxLength: widget.maxLength,
      readOnly: widget.readOnly,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
    );
    if (!widget.enablePrimarySelection) return field;
    return middleClickPaste(onMiddleClick: _pasteAtCursor, child: field);
  }
}
