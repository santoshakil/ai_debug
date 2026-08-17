import 'dart:io';

import 'package:ai_debug/src/builtins/filesystem_tools.dart';
import 'package:ai_debug/src/registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory outside;
  late CommandRegistry registry;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ai_debug_files_root_');
    outside = await Directory.systemTemp.createTemp('ai_debug_files_outside_');
    registry = CommandRegistry();
    registerFilesystemTools(registry, allowedRoots: {root.path});
  });

  tearDown(() async {
    await root.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  test('lists and reads only inside an allowed root', () async {
    final file = File('${root.path}/one.txt');
    await file.writeAsString('hello');

    final list =
        (await registry.dispatch('files.list', {'path': root.path})).json
            as Map<String, Object?>;
    final read =
        (await registry.dispatch('files.read_text', {'path': file.path})).json
            as Map<String, Object?>;

    expect(list['count'], 1);
    expect(read['text'], 'hello');
  });

  test('cuts text at a UTF-8 boundary', () async {
    final file = File('${root.path}/utf8.txt');
    await file.writeAsString('éé');

    final read =
        (await registry.dispatch('files.read_text', {
              'path': file.path,
              'maxBytes': 3,
            })).json
            as Map<String, Object?>;

    expect(read['truncated'], isTrue);
    expect(read['text'], 'é');
  });

  test('totals directory bytes without following links', () async {
    await File('${root.path}/one.bin').writeAsBytes([1, 2, 3]);
    final nested = await Directory('${root.path}/nested').create();
    await File('${nested.path}/two.bin').writeAsBytes([4, 5]);
    final outsideFile = File('${outside.path}/outside.bin');
    await outsideFile.writeAsBytes(List.filled(20, 0));
    await Link('${root.path}/outside-link').create(outsideFile.path);

    final size =
        (await registry.dispatch('files.directory_size', {
              'path': root.path,
              'maxDepth': 4,
              'maxEntries': 20,
            })).json
            as Map<String, Object?>;

    expect(size['bytes'], 5);
    expect(size['files'], 2);
    expect(size['complete'], isTrue);
  });

  test('directory size reports a depth limit', () async {
    final nested = await Directory('${root.path}/nested').create();
    await File('${nested.path}/two.bin').writeAsBytes([4, 5]);

    final size =
        (await registry.dispatch('files.directory_size', {
              'path': root.path,
              'maxDepth': 0,
            })).json
            as Map<String, Object?>;

    expect(size['bytes'], 0);
    expect(size['complete'], isFalse);
    expect(size['truncatedByDepth'], isTrue);
  });

  test('rejects outside paths and symlink escapes', () async {
    final file = File('${outside.path}/secret.txt');
    await file.writeAsString('secret');
    final link = Link('${root.path}/secret-link');
    await link.create(file.path);

    await expectLater(
      registry.dispatch('files.stat', {'path': file.path}),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      registry.dispatch('files.stat', {'path': link.path}),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('supports a filesystem root', () async {
    if (Platform.isWindows) return;
    final rootRegistry = CommandRegistry();
    registerFilesystemTools(rootRegistry, allowedRoots: {'/'});

    final stat =
        (await rootRegistry.dispatch('files.stat', {'path': '/'})).json
            as Map<String, Object?>;
    final child =
        (await rootRegistry.dispatch('files.stat', {
              'path': Directory.systemTemp.path,
            })).json
            as Map<String, Object?>;

    expect(stat['name'], '/');
    expect(child['type'], 'directory');
  });

  test('does not resolve roots during registration', () async {
    final missing = '${root.path}/missing';
    final missingRegistry = CommandRegistry();

    registerFilesystemTools(missingRegistry, allowedRoots: {missing});
    await pumpEventQueue();

    await expectLater(
      missingRegistry.dispatch('files.roots', const {}),
      throwsA(isA<FileSystemException>()),
    );
  });
}
