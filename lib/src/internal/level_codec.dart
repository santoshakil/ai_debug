import 'package:logging/logging.dart';

String loggingLevelToStr(Level l) {
  if (l >= Level.SEVERE) return 'error';
  if (l >= Level.WARNING) return 'warn';
  if (l >= Level.INFO) return 'info';
  if (l >= Level.FINE) return 'debug';
  return 'trace';
}

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
