import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

typedef AiDebugHandler = FutureOr<Object?> Function(Map<String, dynamic> args);

class AiDebugResult {
  final Object? json;
  final Uint8List? binary;
  final String? binaryMime;

  const AiDebugResult._({this.json, this.binary, this.binaryMime});

  factory AiDebugResult.json(Object? value) => AiDebugResult._(json: value);

  factory AiDebugResult.binary(Uint8List bytes, {required String mime}) {
    if (mime.length > 255 ||
        !RegExp(
          r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
        ).hasMatch(mime)) {
      throw ArgumentError.value(mime, 'mime', 'invalid media type');
    }
    return AiDebugResult._(
      binary: Uint8List.fromList(bytes),
      binaryMime: mime.toLowerCase(),
    );
  }
}

class AiDebugSchema {
  final Map<String, dynamic> _json;

  const AiDebugSchema._(this._json);

  Map<String, dynamic> get asJson => _copyMap(_json);

  static AiDebugSchema any() => const AiDebugSchema._({});

  static AiDebugSchema object(
    Map<String, AiDebugSchema> props, {
    List<String> required = const [],
    List<String> requiredAny = const [],
    bool? additionalProperties,
  }) => AiDebugSchema._({
    'type': 'object',
    'properties': {for (final e in props.entries) e.key: e.value._json},
    if (required.isNotEmpty) 'required': required,
    if (requiredAny.isNotEmpty)
      'anyOf': [
        for (final name in requiredAny)
          {
            'required': [name],
          },
      ],
    'additionalProperties': additionalProperties ?? props.isEmpty,
  });

  static AiDebugSchema map({String? description}) => AiDebugSchema._({
    'type': 'object',
    'description': ?description,
    'additionalProperties': true,
  });

  static AiDebugSchema string({
    String? description,
    List<String>? enum_,
    String? default_,
    int? minLength,
    int? maxLength,
  }) => AiDebugSchema._({
    'type': 'string',
    'description': ?description,
    'enum': ?enum_,
    'default': ?default_,
    'minLength': ?minLength,
    'maxLength': ?maxLength,
  });

  static AiDebugSchema integer({
    String? description,
    int? min,
    int? max,
    int? default_,
  }) => AiDebugSchema._({
    'type': 'integer',
    'description': ?description,
    'minimum': ?min,
    'maximum': ?max,
    'default': ?default_,
  });

  static AiDebugSchema number({
    String? description,
    num? min,
    num? max,
    num? default_,
  }) => AiDebugSchema._({
    'type': 'number',
    'description': ?description,
    'minimum': ?min,
    'maximum': ?max,
    'default': ?default_,
  });

  static AiDebugSchema boolean({String? description, bool? default_}) =>
      AiDebugSchema._({
        'type': 'boolean',
        'description': ?description,
        'default': ?default_,
      });

  static AiDebugSchema array(
    AiDebugSchema items, {
    String? description,
    int? minItems,
    int? maxItems,
  }) => AiDebugSchema._({
    'type': 'array',
    'items': items._json,
    'description': ?description,
    'minItems': ?minItems,
    'maxItems': ?maxItems,
  });

  static AiDebugSchema oneOf(List<AiDebugSchema> schemas) {
    final types = schemas.map((schema) => schema._json['type']).toSet();
    return AiDebugSchema._({
      if (types.length == 1 && types.single is String) 'type': types.single,
      'oneOf': [for (final schema in schemas) schema._json],
    });
  }

  static AiDebugSchema empty() => object(const {}, additionalProperties: false);

  void validate(Object? value, {String path = r'$'}) =>
      _validateValue(_json, value, path);

  AiDebugSchema _copy() => AiDebugSchema._(_copyMap(_json));
}

class ToolEntry {
  final String name;
  final String description;
  final String? title;
  final AiDebugSchema inputSchema;
  final AiDebugSchema? outputSchema;
  final Map<String, Object?>? annotations;
  final AiDebugHandler handler;

  const ToolEntry({
    required this.name,
    required this.description,
    this.title,
    required this.inputSchema,
    this.outputSchema,
    this.annotations,
    required this.handler,
  });
}

class CommandRegistry {
  CommandRegistry({Set<String> reservedNames = const {}})
    : _reservedNames = Set.unmodifiable(reservedNames);

  final _tools = <String, ToolEntry>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  final Set<String> _reservedNames;

  Stream<void> get changes => _changes.stream;

  List<ToolEntry> get all {
    final tools = _tools.values.toList(growable: false);
    tools.sort((a, b) => a.name.compareTo(b.name));
    return tools;
  }

  ToolEntry? get(String name) => _tools[name];

  bool add(ToolEntry entry, {bool replace = false}) {
    _validateToolName(entry.name);
    if (_reservedNames.contains(entry.name)) {
      throw ArgumentError.value(entry.name, 'name', 'reserved tool name');
    }
    final fresh = !_tools.containsKey(entry.name);
    if (fresh && _tools.length >= 512) {
      throw StateError('tool registry limit reached');
    }
    if (!fresh && !replace) {
      throw StateError('tool already registered: ${entry.name}');
    }
    if (entry.description.isEmpty || entry.description.length > 4096) {
      throw ArgumentError.value(
        entry.description,
        'description',
        'must contain 1 to 4096 characters',
      );
    }
    if (entry.title != null &&
        (entry.title!.isEmpty || entry.title!.length > 512)) {
      throw ArgumentError.value(
        entry.title,
        'title',
        'must contain 1 to 512 characters',
      );
    }
    _validateSchemaDefinition(entry.inputSchema._json);
    if (entry.inputSchema._json['type'] != 'object') {
      throw ArgumentError('tool input schema root must have object type');
    }
    if (entry.outputSchema != null) {
      _validateSchemaDefinition(entry.outputSchema!._json);
      if (entry.outputSchema!._json['type'] != 'object') {
        throw ArgumentError('tool output schema root must have object type');
      }
    }
    final annotations = entry.annotations == null
        ? null
        : _freezeAnnotations(entry.annotations!);
    if (annotations != null) _validateAnnotations(annotations);
    _checkDefinitionSize({
      'inputSchema': entry.inputSchema._json,
      if (entry.outputSchema != null) 'outputSchema': entry.outputSchema!._json,
      'annotations': ?annotations,
    });
    _tools[entry.name] = ToolEntry(
      name: entry.name,
      description: entry.description,
      title: entry.title,
      inputSchema: entry.inputSchema._copy(),
      outputSchema: entry.outputSchema?._copy(),
      annotations: annotations,
      handler: entry.handler,
    );
    _changes.add(null);
    return fresh;
  }

  bool register(ToolEntry entry) => add(entry, replace: false);

  bool replace(ToolEntry entry) => add(entry, replace: true);

  bool remove(String name) {
    final removed = _tools.remove(name) != null;
    if (removed) _changes.add(null);
    return removed;
  }

  void clear() {
    if (_tools.isEmpty) return;
    _tools.clear();
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();

  Future<AiDebugResult> dispatch(String name, Map<String, dynamic> args) async {
    final entry = _tools[name];
    if (entry == null) throw StateError('unknown tool: $name');
    entry.inputSchema.validate(args);
    final raw = await entry.handler(args);
    final result = raw is AiDebugResult ? raw : AiDebugResult.json(raw);
    if (result.binary == null && entry.outputSchema != null) {
      entry.outputSchema!.validate(result.json, path: r'$.result');
    }
    return result;
  }
}

Map<String, Object?> _freezeAnnotations(Map<dynamic, dynamic> source) {
  final active = HashSet<Object>.identity();
  var nodes = 0;

  Object? freeze(Object? value, int depth) {
    if (++nodes > 10000 || depth > 32) {
      throw ArgumentError('tool annotations exceed structural limits');
    }
    if (value == null || value is bool || value is String) return value;
    if (value is num) {
      if (!value.isFinite) {
        throw ArgumentError('tool annotations must contain finite numbers');
      }
      return value;
    }
    if (value is Map) {
      if (!active.add(value)) {
        throw ArgumentError('tool annotations must not contain cycles');
      }
      try {
        final copy = <String, Object?>{};
        for (final entry in value.entries) {
          final key = entry.key;
          if (key is! String) {
            throw ArgumentError('tool annotation keys must be strings');
          }
          copy[key] = freeze(entry.value, depth + 1);
        }
        return Map<String, Object?>.unmodifiable(copy);
      } finally {
        active.remove(value);
      }
    }
    if (value is List) {
      if (!active.add(value)) {
        throw ArgumentError('tool annotations must not contain cycles');
      }
      try {
        return List<Object?>.unmodifiable(
          value.map((item) => freeze(item, depth + 1)),
        );
      } finally {
        active.remove(value);
      }
    }
    throw ArgumentError('tool annotations must contain only JSON values');
  }

  return freeze(source, 0)! as Map<String, Object?>;
}

void _validateAnnotations(Map<String, Object?> annotations) {
  for (final name in const [
    'readOnlyHint',
    'destructiveHint',
    'idempotentHint',
    'openWorldHint',
  ]) {
    final value = annotations[name];
    if (value != null && value is! bool) {
      throw ArgumentError('$name tool annotation must be a boolean');
    }
  }
  final title = annotations['title'];
  if (title != null &&
      (title is! String || title.isEmpty || title.length > 512)) {
    throw ArgumentError('title tool annotation must contain 1 to 512 chars');
  }
}

void _checkDefinitionSize(Map<String, Object?> value) {
  try {
    if (utf8.encode(jsonEncode(value)).length > 65536) {
      throw ArgumentError('tool schema and annotations exceed 64 KiB');
    }
  } on JsonUnsupportedObjectError {
    throw ArgumentError('tool annotations must be JSON values');
  }
}

class AiDebugSchemaError extends FormatException {
  AiDebugSchemaError(super.message);
}

void _validateToolName(String name) {
  if (name.isEmpty ||
      name.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'invalid tool name');
  }
}

void _validateSchemaDefinition(
  Map<String, dynamic> schema, [
  String path = r'$',
]) {
  if (schema.isEmpty) return;
  final oneOf = schema['oneOf'];
  if (oneOf != null) {
    if (schema.keys.any((key) => key != 'type' && key != 'oneOf') ||
        (schema['type'] != null && schema['type'] is! String) ||
        oneOf is! List ||
        oneOf.isEmpty ||
        oneOf.any((branch) => branch is! Map)) {
      throw ArgumentError('invalid oneOf schema at $path');
    }
    for (var i = 0; i < oneOf.length; i++) {
      _validateSchemaDefinition(
        Map<String, dynamic>.from(oneOf[i] as Map),
        '$path.oneOf[$i]',
      );
    }
    return;
  }
  final type = schema['type'];
  const types = {'object', 'array', 'string', 'integer', 'number', 'boolean'};
  if (type is! String || !types.contains(type)) {
    throw ArgumentError('invalid schema type at $path');
  }
  if (type == 'object') {
    final props = schema['properties'];
    if (props != null &&
        (props is! Map || props.keys.any((key) => key is! String))) {
      throw ArgumentError('invalid object properties at $path');
    }
    for (final entry in (props as Map? ?? const {}).entries) {
      if (entry.value is! Map) {
        throw ArgumentError('invalid schema at $path.${entry.key}');
      }
      _validateSchemaDefinition(
        Map<String, dynamic>.from(entry.value as Map),
        '$path.${entry.key}',
      );
    }
    final required = schema['required'];
    if (required != null &&
        (required is! List || required.any((key) => key is! String))) {
      throw ArgumentError('invalid required list at $path');
    }
    if (required is List &&
        required.any((key) => !(props ?? const {}).containsKey(key))) {
      throw ArgumentError('required property is not defined at $path');
    }
    final anyOf = schema['anyOf'];
    if (anyOf != null &&
        (anyOf is! List ||
            anyOf.isEmpty ||
            anyOf.any((branch) {
              if (branch is! Map || branch.length != 1) return true;
              final names = branch['required'];
              return names is! List ||
                  names.length != 1 ||
                  names.single is! String ||
                  !(props ?? const {}).containsKey(names.single);
            }))) {
      throw ArgumentError('invalid object anyOf at $path');
    }
  }
  if (type == 'array') {
    final items = schema['items'];
    if (items is! Map) throw ArgumentError('invalid array items at $path');
    _validateSchemaDefinition(Map<String, dynamic>.from(items), '$path[]');
    final min = schema['minItems'];
    final max = schema['maxItems'];
    if ((min != null && (min is! int || min < 0)) ||
        (max != null && (max is! int || max < 0)) ||
        (min is int && max is int && min > max)) {
      throw ArgumentError('invalid array length at $path');
    }
  }
  if (type == 'string') {
    final min = schema['minLength'];
    final max = schema['maxLength'];
    if ((min != null && (min is! int || min < 0)) ||
        (max != null && (max is! int || max < 0)) ||
        (min is int && max is int && min > max)) {
      throw ArgumentError('invalid string length at $path');
    }
    final values = schema['enum'];
    if (values != null &&
        (values is! List ||
            values.isEmpty ||
            values.any((value) => value is! String))) {
      throw ArgumentError('invalid string enum at $path');
    }
  }
  if (type == 'integer' || type == 'number') {
    final min = schema['minimum'];
    final max = schema['maximum'];
    if ((min != null && (min is! num || !min.isFinite)) ||
        (max != null && (max is! num || !max.isFinite)) ||
        (min is num && max is num && min > max)) {
      throw ArgumentError('invalid numeric range at $path');
    }
  }
  final defaultValue = schema['default'];
  if (schema.containsKey('default')) {
    try {
      _validateValue(schema, defaultValue, '$path.default');
    } on AiDebugSchemaError catch (error) {
      throw ArgumentError('invalid schema default at $path: ${error.message}');
    }
  }
}

void _validateValue(Map<String, dynamic> schema, Object? value, String path) {
  if (schema.isEmpty) return;
  final oneOf = schema['oneOf'];
  if (oneOf is List) {
    var matches = 0;
    for (final branch in oneOf) {
      try {
        _validateValue(Map<String, dynamic>.from(branch as Map), value, path);
        matches++;
      } on AiDebugSchemaError {
        continue;
      }
    }
    if (matches != 1) _bad(path, 'must match exactly one allowed schema');
    return;
  }
  final type = schema['type'];
  switch (type) {
    case 'object':
      if (value is! Map) _bad(path, 'must be an object');
      final map = value;
      if (map.keys.any((key) => key is! String)) {
        _bad(path, 'must use string keys');
      }
      final props = (schema['properties'] as Map?) ?? const {};
      final required = (schema['required'] as List?) ?? const [];
      for (final key in required) {
        if (!map.containsKey(key)) _bad('$path.$key', 'is required');
      }
      final anyOf = schema['anyOf'] as List?;
      if (anyOf != null &&
          !anyOf.any((branch) {
            final names = (branch as Map)['required'] as List;
            return names.every(map.containsKey);
          })) {
        _bad(path, 'must contain at least one matching property');
      }
      if (schema['additionalProperties'] == false) {
        for (final key in map.keys) {
          if (!props.containsKey(key)) _bad('$path.$key', 'is not allowed');
        }
      }
      for (final entry in props.entries) {
        if (!map.containsKey(entry.key)) continue;
        _validateValue(
          Map<String, dynamic>.from(entry.value as Map),
          map[entry.key],
          '$path.${entry.key}',
        );
      }
      break;
    case 'array':
      if (value is! List) _bad(path, 'must be an array');
      final list = value;
      final min = schema['minItems'] as int?;
      final max = schema['maxItems'] as int?;
      if (min != null && list.length < min) {
        _bad(path, 'must contain at least $min items');
      }
      if (max != null && list.length > max) {
        _bad(path, 'must contain at most $max items');
      }
      final items = schema['items'];
      if (items is Map) {
        for (var i = 0; i < list.length; i++) {
          _validateValue(
            Map<String, dynamic>.from(items),
            list[i],
            '$path[$i]',
          );
        }
      }
      break;
    case 'string':
      if (value is! String) _bad(path, 'must be a string');
      final min = schema['minLength'] as int?;
      final max = schema['maxLength'] as int?;
      if (min != null && value.length < min) {
        _bad(path, 'must contain at least $min characters');
      }
      if (max != null && value.length > max) {
        _bad(path, 'must contain at most $max characters');
      }
      break;
    case 'integer':
      if (value is! int) _bad(path, 'must be an integer');
      break;
    case 'number':
      if (value is! num) _bad(path, 'must be a number');
      break;
    case 'boolean':
      if (value is! bool) _bad(path, 'must be a boolean');
      break;
  }
  final values = schema['enum'];
  if (values is List && !values.contains(value)) {
    _bad(path, 'must be one of ${values.join(', ')}');
  }
  if (value is num) {
    if (!value.isFinite) _bad(path, 'must be finite');
    final min = schema['minimum'] as num?;
    final max = schema['maximum'] as num?;
    if (min != null && value < min) _bad(path, 'must be at least $min');
    if (max != null && value > max) _bad(path, 'must be at most $max');
  }
}

Map<String, dynamic> _copyMap(Map<dynamic, dynamic> source) => {
  for (final entry in source.entries)
    entry.key as String: switch (entry.value) {
      Map<dynamic, dynamic> value => _copyMap(value),
      List<dynamic> value => _copyList(value),
      final value => value,
    },
};

List<dynamic> _copyList(List<dynamic> source) => [
  for (final value in source)
    switch (value) {
      Map<dynamic, dynamic> value => _copyMap(value),
      List<dynamic> value => _copyList(value),
      _ => value,
    },
];

Never _bad(String path, String message) {
  throw AiDebugSchemaError('$path $message');
}
