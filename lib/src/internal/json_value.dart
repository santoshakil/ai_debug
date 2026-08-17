Object? toJsonValue(
  Object? value, {
  int maxDepth = 12,
  int maxItems = 1000,
  int maxStringLength = 16384,
  int maxStringUnits = 1024 * 1024,
  bool truncate = true,
}) {
  if (maxDepth < 1 ||
      maxItems < 1 ||
      maxStringLength < 1 ||
      maxStringUnits < 1) {
    throw ArgumentError('JSON limits must be positive');
  }
  var remaining = maxItems;
  var remainingStringUnits = maxStringUnits;
  final active = <Object>{};

  Never limited() => throw const JsonValueLimitException();

  String text(Object current, [int? limit]) {
    if (remainingStringUnits == 0) {
      if (!truncate) limited();
      return '';
    }
    String value;
    try {
      value = current.toString();
    } catch (_) {
      value = '<unavailable>';
    }
    final length = [
      value.length,
      maxStringLength,
      remainingStringUnits,
      ?limit,
    ].reduce((a, b) => a < b ? a : b);
    if (!truncate && value.length > length) limited();
    remainingStringUnits -= length;
    if (value.length <= length) return value;
    if (length == 0) return '';
    return length == 1 ? '…' : '${value.substring(0, length - 1)}…';
  }

  Object? convert(Object? current, int depth) {
    if (current == null || current is bool) return current;
    if (current is String) return text(current);
    if (current is num) return current.isFinite ? current : current.toString();
    if (current is DateTime) return text(current.toIso8601String());
    if (current is Duration) return current.inMicroseconds;
    if (current is Uri || current is Enum) return text(current);
    if (depth >= maxDepth) {
      if (!truncate) limited();
      return '[depth limit]';
    }
    if (current is Map) {
      if (!active.add(current)) {
        if (!truncate) limited();
        return '[cycle]';
      }
      final result = <String, Object?>{};
      final iterator = current.entries.iterator;
      while (remaining > 0 && iterator.moveNext()) {
        remaining--;
        final entry = iterator.current;
        result[entry.key == null ? 'null' : text(entry.key as Object, 256)] =
            convert(entry.value, depth + 1);
      }
      if (iterator.moveNext()) {
        if (!truncate) limited();
        result['[truncated]'] = true;
      }
      active.remove(current);
      return result;
    }
    if (current is Iterable) {
      if (!active.add(current)) {
        if (!truncate) limited();
        return '[cycle]';
      }
      final result = <Object?>[];
      final iterator = current.iterator;
      while (remaining > 0 && iterator.moveNext()) {
        remaining--;
        result.add(convert(iterator.current, depth + 1));
      }
      if (iterator.moveNext()) {
        if (!truncate) limited();
        result.add('[truncated]');
      }
      active.remove(current);
      return result;
    }
    return text(current);
  }

  return convert(value, 0);
}

class JsonValueLimitException implements Exception {
  const JsonValueLimitException();
}
