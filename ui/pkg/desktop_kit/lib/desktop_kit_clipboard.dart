/// Clipboard support for desktop Linux: CLIPBOARD selection (Ctrl+C/V) with
/// SnackBar feedback, and PRIMARY selection (highlight-to-copy +
/// middle-mouse-click-to-paste) that native Linux apps support natively but
/// Flutter omits.
///
/// ## CLIPBOARD selection
///
/// Use [setClipboard] for a bare write or [readClipboard] for a bare read, or
/// [copyToClipboard] for the combined write + SnackBar feedback pattern.
///
/// ## PRIMARY selection
///
/// Instantiate [PrimarySelection] and:
/// - call [PrimarySelection.write] from your `onSelectionChanged` callback so
///   highlighted text flows into PRIMARY automatically (the standard Linux
///   convention);
/// - wrap your editor in [middleClickPaste] and call [PrimarySelection.read]
///   in the callback to paste on middle-click.
///
/// Session detection ([detectLinuxSession] / [LinuxSession]) is injectable for
/// tests; real detection reads `XDG_SESSION_TYPE`, `WAYLAND_DISPLAY`, and
/// `DISPLAY` from [Platform.environment].
///
/// ## Drop-in field
///
/// [PrimaryTextField] is a controlled [TextField] replacement that bakes in the
/// PRIMARY behaviour above (highlight→copy, middle-click→paste), so apps adopt
/// it in one line instead of re-wiring [PrimarySelection] + [middleClickPaste]
/// per field.
library;

export 'src/clipboard/clipboard.dart'
    show copyToClipboard, readClipboard, setClipboard;
export 'src/clipboard/primary_selection.dart'
    show
        // Re-exported so callers can build a fake ProcessRunner without
        // importing the host layer directly; it replaces dart:io's
        // ProcessResult in this API.
        HostProcessResult,
        LinuxSession,
        PrimarySelection,
        ProcessRunner,
        detectLinuxSession,
        middleClickPaste;
export 'src/clipboard/primary_text_field.dart' show PrimaryTextField;
