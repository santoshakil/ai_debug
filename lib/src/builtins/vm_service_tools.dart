import 'dart:developer' as developer;
import 'dart:isolate';

import '../registry.dart';
import '../vm_service/vm_data.dart';
import '../vm_service/vm_service_client.dart';

void registerVmServiceTools(
  CommandRegistry registry, {
  required bool controls,
}) {
  final client = VmServiceClient.instance;

  registry.add(
    ToolEntry(
      name: 'vm.status',
      description: 'Dart VM service availability and protocol version.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) => client.status(),
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.isolates',
      description: 'Live isolate and isolate-group list from the Dart VM.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) async {
        final vm = await client.call('getVM');
        return {
          'pid': vm['pid'],
          'startedAtMs': vm['startTime'],
          'isolates': _refs(vm['isolates']),
          'isolateGroups': _refs(vm['isolateGroups']),
          'systemIsolates': _refs(vm['systemIsolates']),
          'source': 'vmService',
          'scope': 'current Dart VM',
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.memory',
      description: 'Process and current-isolate memory from the Dart VM.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) async {
        final isolateId = _currentIsolateId();
        final results = await Future.wait([
          client.call('getProcessMemoryUsage'),
          client.call('getMemoryUsage', {'isolateId': isolateId}),
        ]);
        return {
          'process': results[0]['root'],
          'isolate': results[1],
          'isolateId': isolateId,
          'source': 'vmService',
          'scope': 'current Dart VM and current isolate',
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.cpu',
      description:
          'Recent CPU profiler samples for one isolate. Requires a profiler-enabled VM.',
      inputSchema: AiDebugSchema.object({
        'isolateId': AiDebugSchema.string(minLength: 1, maxLength: 512),
        'durationMs': AiDebugSchema.integer(
          min: 10,
          max: 60000,
          default_: 5000,
        ),
        'limit': AiDebugSchema.integer(min: 1, max: 200, default_: 30),
      }),
      annotations: _readOnly,
      handler: (args) async {
        final isolateId = args['isolateId'] as String? ?? _currentIsolateId();
        final durationUs = ((args['durationMs'] as int?) ?? 5000) * 1000;
        final now = await client.call('getVMTimelineMicros');
        final timestamp = _int(now['timestamp']);
        final result = await client.call('getCpuSamples', {
          'isolateId': isolateId,
          'timeOriginMicros': timestamp - durationUs,
          'timeExtentMicros': durationUs,
        });
        return {
          ...VmData.cpu(result, limit: (args['limit'] as int?) ?? 30),
          'isolateId': isolateId,
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.allocations',
      description: 'Live class allocation summary for one isolate.',
      inputSchema: AiDebugSchema.object({
        'isolateId': AiDebugSchema.string(minLength: 1, maxLength: 512),
        if (controls) 'gc': AiDebugSchema.boolean(default_: false),
        if (controls) 'reset': AiDebugSchema.boolean(default_: false),
        'limit': AiDebugSchema.integer(min: 1, max: 500, default_: 50),
      }),
      annotations: controls ? _control : _readOnly,
      handler: (args) async {
        final isolateId = args['isolateId'] as String? ?? _currentIsolateId();
        final result = await client.call('getAllocationProfile', {
          'isolateId': isolateId,
          if (controls && args['gc'] == true) 'gc': true,
          if (controls && args['reset'] == true) 'reset': true,
        });
        return {
          ...VmData.allocations(result, limit: (args['limit'] as int?) ?? 50),
          'isolateId': isolateId,
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.stack',
      description: 'Current stack frames for one isolate.',
      inputSchema: AiDebugSchema.object({
        'isolateId': AiDebugSchema.string(minLength: 1, maxLength: 512),
        'limit': AiDebugSchema.integer(min: 1, max: 200, default_: 50),
      }),
      annotations: _readOnly,
      handler: (args) async {
        final isolateId = args['isolateId'] as String? ?? _currentIsolateId();
        final limit = (args['limit'] as int?) ?? 50;
        final result = await client.call('getStack', {
          'isolateId': isolateId,
          'limit': limit,
        });
        return {
          'isolateId': isolateId,
          'frames': [
            for (final frame in _maps(result['frames']))
              {
                'index': frame['index'],
                'function': _name(frame['function']),
                'location': frame['location'],
              },
          ],
          'messages': result['messages'] ?? const <Object?>[],
          'source': 'vmService',
          'scope': 'one isolate',
        };
      },
    ),
  );

  registry.add(
    ToolEntry(
      name: 'vm.timeline',
      description: 'Recent VM and Flutter timeline events.',
      inputSchema: AiDebugSchema.object({
        'durationMs': AiDebugSchema.integer(
          min: 10,
          max: 60000,
          default_: 5000,
        ),
        'limit': AiDebugSchema.integer(min: 1, max: 5000, default_: 1000),
      }),
      annotations: _readOnly,
      handler: (args) async {
        final durationUs = ((args['durationMs'] as int?) ?? 5000) * 1000;
        final now = await client.call('getVMTimelineMicros');
        final timestamp = _int(now['timestamp']);
        final result = await client.call('getVMTimeline', {
          'timeOriginMicros': timestamp - durationUs,
          'timeExtentMicros': durationUs,
        });
        return VmData.timeline(result, limit: (args['limit'] as int?) ?? 1000);
      },
    ),
  );
}

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _control = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': true,
  'openWorldHint': false,
};

String _currentIsolateId() =>
    developer.Service.getIsolateId(Isolate.current) ??
    (throw StateError('current isolate has no VM service id'));

List<Map<String, Object?>> _refs(Object? raw) => [
  for (final ref in _maps(raw))
    {
      'id': ref['id'],
      'name': ref['name'],
      'number': ref['number'],
      'isSystem': ref['isSystemIsolateGroup'] ?? false,
    },
];

List<Map<String, dynamic>> _maps(Object? raw) => raw is List
    ? [
        for (final item in raw)
          if (item is Map) Map<String, dynamic>.from(item),
      ]
    : [];

String? _name(Object? raw) => raw is Map ? raw['name']?.toString() : null;

int _int(Object? value) => switch (value) {
  int value => value,
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};
