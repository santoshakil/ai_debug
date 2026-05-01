import 'package:logging/logging.dart';

import '../generated/ai_debug.pbenum.dart' as pbe;

/// Convert a protobuf [pbe.LogRecord_Level] into Dart's [Level].
Level pbLevelToLoggingLevel(pbe.LogRecord_Level lvl) {
  switch (lvl) {
    case pbe.LogRecord_Level.TRACE:
      return Level.FINEST;
    case pbe.LogRecord_Level.DEBUG:
      return Level.FINE;
    case pbe.LogRecord_Level.INFO:
      return Level.INFO;
    case pbe.LogRecord_Level.WARN:
      return Level.WARNING;
    case pbe.LogRecord_Level.ERROR:
      return Level.SEVERE;
  }
  return Level.INFO;
}

/// Short-form level string used in all JSON payloads (merged log tail etc.).
String loggingLevelToStr(Level l) {
  if (l >= Level.SEVERE) return 'error';
  if (l >= Level.WARNING) return 'warn';
  if (l >= Level.INFO) return 'info';
  if (l >= Level.FINE) return 'debug';
  return 'trace';
}

/// Parse a short-form level string back into a [Level].
Level? parseLoggingLevel(String s) {
  switch (s.toLowerCase()) {
    case 'trace':
    case 'finest':
      return Level.FINEST;
    case 'debug':
    case 'fine':
      return Level.FINE;
    case 'info':
      return Level.INFO;
    case 'warn':
    case 'warning':
      return Level.WARNING;
    case 'error':
    case 'severe':
      return Level.SEVERE;
    case 'off':
      return Level.OFF;
    case 'all':
      return Level.ALL;
  }
  return null;
}
