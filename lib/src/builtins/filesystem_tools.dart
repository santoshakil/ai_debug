import 'dart:convert';
import 'dart:io';

import '../registry.dart';

void registerFilesystemTools(
  CommandRegistry registry, {
  required Set<String> allowedRoots,
}) {
  final access = _FileAccess(allowedRoots);
  registry.add(
    ToolEntry(
      name: 'files.roots',
      description: 'Configured filesystem roots available to ai_debug.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) async => {'roots': await access.roots},
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.stat',
      description: 'Metadata for a file or directory inside an allowed root.',
      inputSchema: _pathSchema,
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        return _stat(path);
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.list',
      description: 'Bounded directory listing inside an allowed root.',
      inputSchema: AiDebugSchema.object(
        {
          'path': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'limit': AiDebugSchema.integer(min: 1, max: 2000, default_: 200),
        },
        required: ['path'],
      ),
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        final limit = args['limit'] as int? ?? 200;
        final entries = <Map<String, Object?>>[];
        var truncated = false;
        await for (final entity in Directory(path).list(followLinks: false)) {
          if (entries.length == limit) {
            truncated = true;
            break;
          }
          final type = await FileSystemEntity.type(
            entity.path,
            followLinks: false,
          );
          entries.add(await _stat(entity.path, type: type, followLinks: false));
        }
        entries.sort(
          (a, b) => (a['name']! as String).compareTo(b['name']! as String),
        );
        return {
          'path': path,
          'count': entries.length,
          'truncated': truncated,
          'entries': entries,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.walk',
      description: 'Bounded recursive tree inside an allowed root.',
      inputSchema: AiDebugSchema.object(
        {
          'path': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'maxDepth': AiDebugSchema.integer(min: 0, max: 32, default_: 8),
          'maxEntries': AiDebugSchema.integer(
            min: 1,
            max: 10000,
            default_: 1000,
          ),
        },
        required: ['path'],
      ),
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        final maxDepth = args['maxDepth'] as int? ?? 8;
        final maxEntries = args['maxEntries'] as int? ?? 1000;
        final entries = <Map<String, Object?>>[];
        var truncated = false;
        var directories = <Directory>[Directory(path)];
        for (
          var depth = 1;
          depth <= maxDepth && directories.isNotEmpty;
          depth++
        ) {
          final next = <Directory>[];
          for (final directory in directories) {
            await for (final entity in directory.list(followLinks: false)) {
              if (entries.length == maxEntries) {
                truncated = true;
                break;
              }
              final type = await FileSystemEntity.type(
                entity.path,
                followLinks: false,
              );
              entries.add(
                await _stat(entity.path, type: type, followLinks: false)
                  ..['depth'] = depth,
              );
              if (type == FileSystemEntityType.directory && depth < maxDepth) {
                next.add(Directory(entity.path));
              }
            }
            if (truncated) break;
          }
          if (truncated) break;
          directories = next;
        }
        return {
          'path': path,
          'count': entries.length,
          'truncated': truncated,
          'entries': entries,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.read_text',
      description: 'Read bounded UTF-8 text inside an allowed root.',
      inputSchema: AiDebugSchema.object(
        {
          'path': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'maxBytes': AiDebugSchema.integer(
            min: 1,
            max: 1048576,
            default_: 65536,
          ),
        },
        required: ['path'],
      ),
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        final maxBytes = args['maxBytes'] as int? ?? 65536;
        final file = File(path);
        final size = await file.length();
        final bytes = await file
            .openRead(0, size.clamp(0, maxBytes))
            .fold(<int>[], (all, chunk) => all..addAll(chunk));
        return {
          'path': path,
          'size': size,
          'truncated': size > maxBytes,
          'text': _decodeUtf8Prefix(bytes, size > maxBytes),
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.directory_size',
      description:
          'Bounded file-byte total for a directory inside an allowed root.',
      inputSchema: AiDebugSchema.object(
        {
          'path': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'maxDepth': AiDebugSchema.integer(min: 0, max: 32, default_: 8),
          'maxEntries': AiDebugSchema.integer(
            min: 1,
            max: 10000,
            default_: 1000,
          ),
        },
        required: ['path'],
      ),
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        final maxDepth = args['maxDepth'] as int? ?? 8;
        final maxEntries = args['maxEntries'] as int? ?? 1000;
        final pending = <({Directory directory, int depth})>[
          (directory: Directory(path), depth: 0),
        ];
        var entries = 0;
        var files = 0;
        var directories = 0;
        var bytes = 0;
        var truncatedByEntries = false;
        var truncatedByDepth = false;
        while (pending.isNotEmpty && !truncatedByEntries) {
          final current = pending.removeLast();
          await for (final entity in current.directory.list(
            followLinks: false,
          )) {
            if (entries == maxEntries) {
              truncatedByEntries = true;
              break;
            }
            entries++;
            final type = await FileSystemEntity.type(
              entity.path,
              followLinks: false,
            );
            if (type == FileSystemEntityType.file) {
              files++;
              bytes += await File(entity.path).length();
            } else if (type == FileSystemEntityType.directory) {
              directories++;
              if (current.depth < maxDepth) {
                pending.add((
                  directory: Directory(entity.path),
                  depth: current.depth + 1,
                ));
              } else {
                truncatedByDepth = true;
              }
            }
          }
        }
        return {
          'path': path,
          'bytes': bytes,
          'files': files,
          'directories': directories,
          'visitedEntries': entries,
          'complete': !truncatedByEntries && !truncatedByDepth,
          'truncatedByEntries': truncatedByEntries,
          'truncatedByDepth': truncatedByDepth,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'files.read_bytes',
      description: 'Read one bounded base64 file slice inside an allowed root.',
      inputSchema: AiDebugSchema.object(
        {
          'path': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'offset': AiDebugSchema.integer(min: 0, default_: 0),
          'length': AiDebugSchema.integer(
            min: 1,
            max: 1048576,
            default_: 65536,
          ),
        },
        required: ['path'],
      ),
      annotations: _readOnly,
      handler: (args) async {
        final path = await access.resolve(args['path'] as String);
        final offset = args['offset'] as int? ?? 0;
        final length = args['length'] as int? ?? 65536;
        final file = File(path);
        final size = await file.length();
        final end = (offset + length).clamp(0, size);
        final bytes = offset >= size
            ? const <int>[]
            : await file
                  .openRead(offset, end)
                  .fold(<int>[], (all, chunk) => all..addAll(chunk));
        return {
          'path': path,
          'offset': offset,
          'returnedBytes': bytes.length,
          'size': size,
          'eof': end >= size,
          'data': base64Encode(bytes),
        };
      },
    ),
  );
}

class _FileAccess {
  _FileAccess(Set<String> roots) : _configured = List.unmodifiable(roots);

  final List<String> _configured;
  Future<List<String>>? _resolved;

  Future<List<String>> get roots => _resolved ??= Future.wait([
    for (final root in _configured) Directory(root).resolveSymbolicLinks(),
  ]).then((values) => List<String>.unmodifiable(values));

  Future<String> resolve(String requested) async {
    final entity = switch (FileSystemEntity.typeSync(requested)) {
      FileSystemEntityType.directory => Directory(requested),
      FileSystemEntityType.file => File(requested),
      FileSystemEntityType.link => Link(requested),
      FileSystemEntityType.notFound => throw FileSystemException(
        'path does not exist',
        requested,
      ),
      FileSystemEntityType.pipe || FileSystemEntityType.unixDomainSock =>
        throw FileSystemException('unsupported file type', requested),
      _ => throw FileSystemException('unsupported file type', requested),
    };
    final resolved = await entity.resolveSymbolicLinks();
    final allowed = await roots;
    if (!allowed.any((root) => _inside(resolved, root))) {
      throw FileSystemException('path is outside allowed roots', requested);
    }
    return resolved;
  }
}

Future<Map<String, Object?>> _stat(
  String path, {
  FileSystemEntityType? type,
  bool followLinks = true,
}) async {
  final actualType =
      type ?? await FileSystemEntity.type(path, followLinks: followLinks);
  if (actualType == FileSystemEntityType.link && !followLinks) {
    return {'path': path, 'name': _name(path), 'type': 'link'};
  }
  final stat = await FileStat.stat(path);
  return {
    'path': path,
    'name': _name(path),
    'type': _typeName(stat.type),
    'size': stat.size,
    'modified': stat.modified.toIso8601String(),
    'accessed': stat.accessed.toIso8601String(),
  };
}

List<String> _parts(String path) => path
    .split(Platform.pathSeparator)
    .where((part) => part.isNotEmpty)
    .toList();

String _name(String path) {
  final parts = _parts(path);
  return parts.isEmpty ? Platform.pathSeparator : parts.last;
}

bool _inside(String path, String root) {
  final separator = Platform.pathSeparator;
  return path == root ||
      path.startsWith(root.endsWith(separator) ? root : '$root$separator');
}

String _decodeUtf8Prefix(List<int> bytes, bool truncated) {
  if (!truncated) return utf8.decode(bytes);
  for (var removed = 0; removed <= 3 && removed <= bytes.length; removed++) {
    try {
      return utf8.decode(bytes.sublist(0, bytes.length - removed));
    } on FormatException {
      if (removed == 3 || removed == bytes.length) rethrow;
    }
  }
  throw const FormatException('invalid UTF-8');
}

String _typeName(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.directory => 'directory',
  FileSystemEntityType.file => 'file',
  FileSystemEntityType.link => 'link',
  FileSystemEntityType.pipe => 'pipe',
  FileSystemEntityType.unixDomainSock => 'unixDomainSocket',
  _ => 'notFound',
};

final _pathSchema = AiDebugSchema.object(
  {'path': AiDebugSchema.string(minLength: 1, maxLength: 4096)},
  required: ['path'],
);

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};
