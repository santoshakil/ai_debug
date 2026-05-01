import 'dart:async';

import 'package:ai_debug/ai_debug.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[${r.level.name}] [${r.loggerName}] ${r.message}');
    }
  });

  await AiDebug.start(appId: 'ai_debug_minimal_app');

  AiDebug.register(
    name: 'ping',
    description: 'Reply with {ok: true}',
    handler: (args) async => {'ok': true, 'echo': args},
  );

  AiDebug.register(
    name: 'emit_log',
    description: 'Emit a log at the given level',
    inputSchema: AiDebugSchema.object({
      'level': AiDebugSchema.string(default_: 'info', enum_: ['trace', 'debug', 'info', 'warn', 'error']),
      'message': AiDebugSchema.string(),
    }),
    handler: (args) async {
      final level = args['level'] as String? ?? 'info';
      final msg = args['message'] as String? ?? 'hello from ai_debug';
      final l = switch (level) {
        'trace' => Level.FINEST,
        'debug' => Level.FINE,
        'info' => Level.INFO,
        'warn' => Level.WARNING,
        'error' => Level.SEVERE,
        _ => Level.INFO,
      };
      Logger('demo').log(l, msg);
      return {'ok': true};
    },
  );

  runApp(const _DemoApp());
}

class _DemoApp extends StatefulWidget {
  const _DemoApp();
  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  Timer? _heartbeat;
  final _log = Logger('demo');
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _heartbeat = Timer.periodic(const Duration(seconds: 3), (t) {
      setState(() => _ticks = t.tick);
      _log.info('heartbeat #${t.tick}');
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai_debug demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('ai_debug demo')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('server: http://<device>:9999', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 12),
              Text('heartbeats: $_ticks'),
              const SizedBox(height: 24),
              const SelectableText('GET /api/tools\nGET /api/logs', style: TextStyle(fontFamily: 'Menlo')),
            ],
          ),
        ),
      ),
    );
  }
}
