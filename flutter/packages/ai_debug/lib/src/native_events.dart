import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

/// Event id that tags every message on the native port.
/// Matches `EventId` in Rust `events.rs`.
enum NativeEventId { envelope }

class NativeEnvelope {
  final NativeEventId id;
  final Uint8List bytes;

  NativeEnvelope(this.id, this.bytes);
}

/// Receive side for `NativeEventPort` pushes from Rust.
///
/// Usage:
///   final rx = NativeEventReceiver();
///   rx.events.listen((e) { ... });     // starts listening
///   final port = rx.nativePortId;      // pass this to ai_debug_init on Rust side
class NativeEventReceiver {
  final _controller = StreamController<NativeEnvelope>.broadcast();
  final _port = ReceivePort('ai_debug.rust');
  StreamSubscription<dynamic>? _sub;
  bool _disposed = false;

  NativeEventReceiver() {
    _sub = _port.listen((msg) {
      if (msg is! List || msg.isEmpty) return;
      final id = msg[0];
      if (id is! int || id < 0 || id >= NativeEventId.values.length) return;
      final eventId = NativeEventId.values[id];
      if (msg.length >= 2 && msg[1] is Uint8List) {
        _controller.add(NativeEnvelope(eventId, msg[1] as Uint8List));
      }
    });
  }

  Stream<NativeEnvelope> get events => _controller.stream;

  int get nativePortId => _port.sendPort.nativePort;

  /// Pointer returned by `NativeApi.initializeApiDLData`. Pass to
  /// Rust's `ai_debug_init` so it can post back to this port.
  Pointer<Void> get dartApiData => NativeApi.initializeApiDLData;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _port.close();
    _controller.close();
  }
}
