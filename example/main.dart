import 'package:ai_debug/ai_debug.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _requested = bool.fromEnvironment('AI_DEBUG');
const _token = String.fromEnvironment('AI_DEBUG_TOKEN');
var _started = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode && _requested && _token.length >= 32) {
    await AiDebug.start(
      config: AiDebugConfig(
        appId: 'ai_debug_example',
        port: 0,
        token: _token,
        features: const AiDebugFeatures(automation: true, screenshots: true),
        automation: const UiAutomationConfig(allowInput: false),
      ),
    );
    _started = true;
  }
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('ai_debug')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_started ? 'bridge ready' : 'bridge off'),
            const SizedBox(height: 12),
            AiDebugTarget(
              id: 'counter.increment',
              child: FilledButton(
                onPressed: () {},
                child: const Text('Tap me'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
