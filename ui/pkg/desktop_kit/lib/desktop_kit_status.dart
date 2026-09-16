/// Status indicators: the [LedIndicator] dot ([LedStatus] off/red/orange/
/// green/blue/gray with glow, named sizes, optional pulse — suppressed for
/// inert statuses and under reduced motion — high-contrast borders, and ARIA
/// labels).
///
/// Domain derivation rules (which status an object maps to) stay app-side;
/// the kit renders what it is handed.
library desktop_kit_status;

export 'src/status/led_indicator.dart';
