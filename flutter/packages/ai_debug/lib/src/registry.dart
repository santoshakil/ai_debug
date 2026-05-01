import 'dart:typed_data';

/// Handler signature for a registered command.
///
/// [args] is the JSON-decoded input from the caller (plain Dart types).
/// Return:
///   * `Map<String, dynamic>` / `List` / `num` / `bool` / `String` — auto-JSON
///   * `AiDebugResult.binary(bytes, mime: ...)` — raw bytes (e.g., PNG)
///   * Throw an exception for errors
typedef AiDebugHandler = Future<Object?> Function(Map<String, dynamic> args);

/// Typed result. For simple cases just return the raw Dart value from
/// your handler — the package auto-wraps it. Use [binary] for raw bytes.
class AiDebugResult {
  final Object? json;
  final Uint8List? binary;
  final String? binaryMime;

  const AiDebugResult._({this.json, this.binary, this.binaryMime});

  factory AiDebugResult.json(Object? value) =>
      AiDebugResult._(json: value);

  factory AiDebugResult.binary(Uint8List bytes, {required String mime}) =>
      AiDebugResult._(binary: bytes, binaryMime: mime);
}

/// Tiny JSON Schema helper — keeps registration readable without a hard dep.
class AiDebugSchema {
  final Map<String, dynamic> asJson;
  const AiDebugSchema._(this.asJson);

  static AiDebugSchema object(Map<String, AiDebugSchema> props, {
    List<String> required = const [],
  }) {
    return AiDebugSchema._({
      'type': 'object',
      'properties': {for (final e in props.entries) e.key: e.value.asJson},
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    });
  }

  static AiDebugSchema string({String? description, List<String>? enum_, String? default_}) =>
      AiDebugSchema._({
        'type': 'string',
        if (description != null) 'description': description,
        if (enum_ != null) 'enum': enum_,
        if (default_ != null) 'default': default_,
      });

  static AiDebugSchema integer({String? description, int? min, int? max, int? default_}) =>
      AiDebugSchema._({
        'type': 'integer',
        if (description != null) 'description': description,
        if (min != null) 'minimum': min,
        if (max != null) 'maximum': max,
        if (default_ != null) 'default': default_,
      });

  static AiDebugSchema number({String? description, num? min, num? max, num? default_}) =>
      AiDebugSchema._({
        'type': 'number',
        if (description != null) 'description': description,
        if (min != null) 'minimum': min,
        if (max != null) 'maximum': max,
        if (default_ != null) 'default': default_,
      });

  static AiDebugSchema boolean({String? description, bool? default_}) =>
      AiDebugSchema._({
        'type': 'boolean',
        if (description != null) 'description': description,
        if (default_ != null) 'default': default_,
      });

  static AiDebugSchema array(AiDebugSchema items, {String? description, int? minItems}) =>
      AiDebugSchema._({
        'type': 'array',
        'items': items.asJson,
        if (description != null) 'description': description,
        if (minItems != null) 'minItems': minItems,
      });

  /// No-args convenience.
  static AiDebugSchema empty() => object(const {});
}

class ToolEntry {
  final String name;
  final String description;
  final AiDebugSchema inputSchema;
  final AiDebugHandler handler;
  final bool streaming;

  const ToolEntry({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.streaming = false,
  });
}

class CommandRegistry {
  final _tools = <String, ToolEntry>{};

  List<ToolEntry> get all => _tools.values.toList(growable: false);

  ToolEntry? get(String name) => _tools[name];

  bool add(ToolEntry entry) {
    final existed = _tools.containsKey(entry.name);
    _tools[entry.name] = entry;
    return !existed;
  }

  bool remove(String name) => _tools.remove(name) != null;

  Future<AiDebugResult> dispatch(String name, Map<String, dynamic> args) async {
    final entry = _tools[name];
    if (entry == null) {
      throw StateError('unknown tool: $name');
    }
    final raw = await entry.handler(args);
    if (raw is AiDebugResult) return raw;
    return AiDebugResult.json(raw);
  }
}
