# Example

`main.dart` shows opt-in debug/profile startup with a local token, feature
gates, inspection-only automation, and a stable automation target.

The example has no nested package or platform runners. Copy it into a Flutter
app or use it as an integration reference. After copying it into an app:

```bash
export AI_DEBUG_TOKEN='use-a-long-local-secret'
flutter run \
  --dart-define=AI_DEBUG=true \
  --dart-define=AI_DEBUG_TOKEN="$AI_DEBUG_TOKEN"
```
