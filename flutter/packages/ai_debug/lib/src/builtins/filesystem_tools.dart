import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../registry.dart';

/// Filesystem inspection tools — list app dirs, recursive size, file listings,
/// disk free, file head/tail. No external deps; uses dart:io only.
///
/// On iOS/Android the canonical paths are platform-specific. We resolve them
/// via the standard Flutter `path_provider` MethodChannels directly so that
/// the package stays dependency-free.
void registerFilesystemTools(CommandRegistry registry) {
  registry.add(ToolEntry(
    name: 'fs_app_dirs',
    description:
        'Return platform app directory paths: documents, support, library, cache, temp. '
        'Resolved via the path_provider method channels.',
    inputSchema: AiDebugSchema.empty(),
    handler: (_) async {
      Future<String?> q(String method) async {
        try {
          final r = await const MethodChannel('plugins.flutter.io/path_provider').invokeMethod<String>(method);
          return r;
        } on MissingPluginException {
          return null;
        } catch (_) {
          return null;
        }
      }

      String? tempDir;
      try {
        tempDir = Directory.systemTemp.path;
      } catch (_) {}

      return {
        'temporary': await q('getTemporaryDirectory') ?? tempDir,
        'applicationDocuments': await q('getApplicationDocumentsDirectory'),
        'applicationSupport': await q('getApplicationSupportDirectory'),
        'applicationCache': await q('getApplicationCacheDirectory'),
        'libraryDir': await q('getLibraryDirectory'),
        'externalStorage': await q('getStorageDirectory'),
        'externalCache': await q('getExternalCacheDirectory'),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_dir_size',
    description:
        'Recursive directory size in bytes. Optionally also returns count of files+dirs. '
        'Skips symlinks. Returns -1 in totalBytes if path missing or perm denied.',
    inputSchema: AiDebugSchema.object(
      {
        'path': AiDebugSchema.string(),
        'maxDepth': AiDebugSchema.integer(default_: 32, min: 0, max: 128),
      },
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      final maxDepth = (args['maxDepth'] as num?)?.toInt() ?? 32;
      final dir = Directory(p);
      if (!dir.existsSync()) {
        return {'ok': false, 'error': 'not-found', 'path': p};
      }
      var bytes = 0;
      var fileCount = 0;
      var dirCount = 0;
      try {
        await for (final ent in dir.list(recursive: true, followLinks: false)) {
          final depth = ent.path.split(Platform.pathSeparator).length -
              p.split(Platform.pathSeparator).length;
          if (depth > maxDepth) continue;
          if (ent is File) {
            try {
              bytes += await ent.length();
              fileCount++;
            } catch (_) {}
          } else if (ent is Directory) {
            dirCount++;
          }
        }
      } catch (e) {
        return {
          'ok': false,
          'error': e.toString(),
          'path': p,
          'partialBytes': bytes,
          'partialFileCount': fileCount,
        };
      }
      return {
        'ok': true,
        'path': p,
        'totalBytes': bytes,
        'fileCount': fileCount,
        'dirCount': dirCount,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_listing',
    description:
        'List a directory non-recursively. Returns name, type (file/dir/link), size, modified.',
    inputSchema: AiDebugSchema.object(
      {
        'path': AiDebugSchema.string(),
        'limit': AiDebugSchema.integer(default_: 200, min: 1, max: 5000),
      },
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      final limit = (args['limit'] as num?)?.toInt() ?? 200;
      final dir = Directory(p);
      if (!dir.existsSync()) {
        return {'ok': false, 'error': 'not-found', 'path': p};
      }
      final entries = <Map<String, dynamic>>[];
      try {
        var i = 0;
        await for (final ent in dir.list(recursive: false, followLinks: false)) {
          if (i++ >= limit) break;
          final stat = await FileStat.stat(ent.path);
          entries.add({
            'name': ent.path.split(Platform.pathSeparator).last,
            'fullPath': ent.path,
            'type': stat.type.toString().split('.').last,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          });
        }
      } catch (e) {
        return {'ok': false, 'error': e.toString(), 'path': p, 'partial': entries};
      }
      return {'ok': true, 'path': p, 'count': entries.length, 'entries': entries};
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_read_text',
    description:
        'Read a small UTF-8 text file. Returns contents (truncated to maxBytes). '
        'Errors if file >maxBytes or missing.',
    inputSchema: AiDebugSchema.object(
      {
        'path': AiDebugSchema.string(),
        'maxBytes': AiDebugSchema.integer(default_: 65536, min: 1, max: 1048576),
      },
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      final maxBytes = (args['maxBytes'] as num?)?.toInt() ?? 65536;
      final f = File(p);
      if (!f.existsSync()) return {'ok': false, 'error': 'not-found', 'path': p};
      final size = await f.length();
      if (size > maxBytes) {
        final stream = f.openRead(0, maxBytes);
        final bytes = <int>[];
        await for (final c in stream) {
          bytes.addAll(c);
        }
        return {
          'ok': true,
          'path': p,
          'size': size,
          'truncated': true,
          'text': String.fromCharCodes(bytes),
        };
      }
      final text = await f.readAsString();
      return {'ok': true, 'path': p, 'size': size, 'text': text};
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_stat',
    description:
        'Stat a single file or directory. Returns type, size, modified, accessed, mode (octal). '
        'Cheap call — use before fs_read_bytes to know totalSize.',
    inputSchema: AiDebugSchema.object(
      {'path': AiDebugSchema.string()},
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      final stat = await FileStat.stat(p);
      if (stat.type == FileSystemEntityType.notFound) {
        return {'ok': false, 'error': 'not-found', 'path': p};
      }
      return {
        'ok': true,
        'path': p,
        'type': stat.type.toString().split('.').last,
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
        'accessed': stat.accessed.toIso8601String(),
        'mode': stat.mode.toRadixString(8),
        'modeString': stat.modeString(),
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_walk',
    description:
        'Recursively list a directory tree. Returns entries with type, size, modified. '
        'Bounded by maxDepth + maxEntries; optional regex filter on relative path. '
        'Skips symlinks. For listing every file in the app sandbox, walk each fs_app_dirs path.',
    inputSchema: AiDebugSchema.object(
      {
        'path': AiDebugSchema.string(description: 'Absolute path to start walk.'),
        'maxDepth': AiDebugSchema.integer(default_: 10, min: 0, max: 64),
        'maxEntries': AiDebugSchema.integer(default_: 5000, min: 1, max: 50000),
        'pattern': AiDebugSchema.string(description: 'Optional regex applied to entry path relative to root. Leave empty to list all.'),
        'includeFiles': AiDebugSchema.boolean(default_: true),
        'includeDirs': AiDebugSchema.boolean(default_: true),
      },
      required: ['path'],
    ),
    handler: (args) async {
      final root = args['path'] as String;
      final maxDepth = (args['maxDepth'] as num?)?.toInt() ?? 10;
      final maxEntries = (args['maxEntries'] as num?)?.toInt() ?? 5000;
      final pattern = (args['pattern'] as String?)?.trim() ?? '';
      final includeFiles = args['includeFiles'] as bool? ?? true;
      final includeDirs = args['includeDirs'] as bool? ?? true;
      final dir = Directory(root);
      if (!dir.existsSync()) {
        return {'ok': false, 'error': 'not-found', 'path': root};
      }
      RegExp? re;
      if (pattern.isNotEmpty) {
        try {
          re = RegExp(pattern);
        } on FormatException catch (e) {
          return {'ok': false, 'error': 'bad-pattern', 'detail': e.message};
        }
      }
      final rootDepth = root.split(Platform.pathSeparator).length;
      final entries = <Map<String, dynamic>>[];
      var totalBytes = 0;
      var truncated = false;
      try {
        await for (final ent in dir.list(recursive: true, followLinks: false)) {
          if (entries.length >= maxEntries) {
            truncated = true;
            break;
          }
          final depth = ent.path.split(Platform.pathSeparator).length - rootDepth;
          if (depth > maxDepth) continue;
          final isDir = ent is Directory;
          if (isDir && !includeDirs) continue;
          if (!isDir && !includeFiles) continue;
          final relative = ent.path.substring(root.length).replaceAll(RegExp('^${RegExp.escape(Platform.pathSeparator)}+'), '');
          if (re != null && !re.hasMatch(relative)) continue;
          final stat = await FileStat.stat(ent.path);
          if (!isDir) totalBytes += stat.size;
          entries.add({
            'path': ent.path,
            'relative': relative,
            'type': stat.type.toString().split('.').last,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
            'depth': depth,
          });
        }
      } catch (e) {
        return {
          'ok': false,
          'error': e.toString(),
          'path': root,
          'partial': entries,
          'partialBytes': totalBytes,
        };
      }
      return {
        'ok': true,
        'path': root,
        'count': entries.length,
        'totalBytes': totalBytes,
        'truncated': truncated,
        'entries': entries,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_read_bytes',
    description:
        'Read a slice of any file as base64. For files larger than chunkSize use offset+chunkSize to '
        'page through. Returns {data, offset, returnedBytes, totalSize, eof}. Default chunkSize 1 MiB.',
    inputSchema: AiDebugSchema.object(
      {
        'path': AiDebugSchema.string(),
        'offset': AiDebugSchema.integer(default_: 0, min: 0),
        'chunkSize': AiDebugSchema.integer(default_: 1048576, min: 1, max: 16777216),
      },
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      final offset = (args['offset'] as num?)?.toInt() ?? 0;
      final chunkSize = (args['chunkSize'] as num?)?.toInt() ?? 1048576;
      final f = File(p);
      if (!f.existsSync()) {
        return {'ok': false, 'error': 'not-found', 'path': p};
      }
      final totalSize = await f.length();
      if (offset >= totalSize) {
        return {
          'ok': true,
          'path': p,
          'offset': offset,
          'returnedBytes': 0,
          'totalSize': totalSize,
          'eof': true,
          'data': '',
        };
      }
      final end = (offset + chunkSize).clamp(0, totalSize);
      final stream = f.openRead(offset, end);
      final bytes = <int>[];
      await for (final c in stream) {
        bytes.addAll(c);
      }
      final data = base64Encode(bytes);
      return {
        'ok': true,
        'path': p,
        'offset': offset,
        'returnedBytes': bytes.length,
        'totalSize': totalSize,
        'eof': end >= totalSize,
        'data': data,
      };
    },
  ));

  registry.add(ToolEntry(
    name: 'fs_disk_free',
    description:
        'Disk free + total bytes for a given path (uses Process df -k).'
        ' Best-effort, may not work on all platforms.',
    inputSchema: AiDebugSchema.object(
      {'path': AiDebugSchema.string()},
      required: ['path'],
    ),
    handler: (args) async {
      final p = args['path'] as String;
      try {
        final res = await Process.run('df', ['-k', p]);
        if (res.exitCode != 0) {
          return {'ok': false, 'error': 'df-failed', 'stderr': res.stderr.toString()};
        }
        final lines = (res.stdout as String).trim().split('\n');
        if (lines.length < 2) return {'ok': false, 'error': 'no-data'};
        final parts = lines[1].split(RegExp(r'\s+'));
        if (parts.length < 6) return {'ok': false, 'error': 'parse-failed'};
        final totalKb = int.tryParse(parts[1]) ?? 0;
        final usedKb = int.tryParse(parts[2]) ?? 0;
        final freeKb = int.tryParse(parts[3]) ?? 0;
        return {
          'ok': true,
          'totalBytes': totalKb * 1024,
          'usedBytes': usedKb * 1024,
          'freeBytes': freeKb * 1024,
          'mountedOn': parts.length > 5 ? parts[5] : null,
        };
      } catch (e) {
        return {'ok': false, 'error': e.toString()};
      }
    },
  ));
}
