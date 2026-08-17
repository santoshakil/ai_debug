import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../version.dart';

class MdnsAdvertiser {
  MdnsAdvertiser._();

  static final MdnsAdvertiser instance = MdnsAdvertiser._();

  static final _group = InternetAddress('224.0.0.251');
  static const _service = '_ai-debug._tcp.local.';
  static const _responseInterval = Duration(milliseconds: 250);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;
  String? _instance;
  String? _host;
  int? _port;
  List<InternetAddress> _addresses = const [];
  final Stopwatch _clock = Stopwatch()..start();
  final MdnsResponseLimiter _responses = MdnsResponseLimiter(_responseInterval);

  bool get isRunning => _socket != null;
  String? get hostname => _host;

  Future<void> start({
    required String appId,
    required int port,
    required InternetAddress address,
  }) async {
    final host = mdnsHostname(appId);
    final instance = '${host.substring(0, host.length - 7)}.$_service';
    if (_socket != null) {
      if (_instance == instance && _host == host && _port == port) return;
      throw StateError('mDNS is already running with different settings');
    }
    final addresses = await mdnsAddressesFor(address);
    if (addresses.isEmpty) {
      throw StateError('mDNS requires a reachable non-loopback address');
    }
    _instance = instance;
    _host = host;
    _port = port;
    _addresses = addresses;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
        reusePort: true,
      );
      socket
        ..multicastLoopback = false
        ..joinMulticast(_group);
      _socket = socket;
      _subscription = socket.listen(_onEvent);
      _announce();
      _timer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _tryAnnounce(),
      );
    } catch (_) {
      socket?.close();
      _instance = null;
      _host = null;
      _port = null;
      _addresses = const [];
      rethrow;
    }
  }

  Future<void> stop() async {
    final socket = _socket;
    if (socket == null) return;
    Object? error;
    StackTrace? stack;
    try {
      _announce(ttl: 0);
    } catch (nextError, nextStack) {
      error = nextError;
      stack = nextStack;
    }
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    _socket = null;
    _instance = null;
    _host = null;
    _port = null;
    _addresses = const [];
    try {
      await subscription?.cancel();
    } catch (nextError, nextStack) {
      error ??= nextError;
      stack ??= nextStack;
    }
    socket.close();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram != null && mdnsQueryMatches(datagram.data, _instance)) {
      final now = _clock.elapsedMicroseconds;
      if (!_responses.take(now)) return;
      _tryAnnounce();
    }
  }

  void _tryAnnounce() {
    try {
      _announce();
    } catch (_) {}
  }

  void _announce({int ttl = 120}) {
    final socket = _socket;
    final instance = _instance;
    final host = _host;
    final port = _port;
    if (socket == null || instance == null || host == null || port == null) {
      return;
    }
    final packet = MdnsPacketBuilder.response(
      service: _service,
      instance: instance,
      host: host,
      port: port,
      addresses: _addresses,
      ttl: ttl,
    );
    socket.send(packet, _group, 5353);
  }
}

class MdnsPacketBuilder {
  static Uint8List response({
    required String service,
    required String instance,
    required String host,
    required int port,
    required List<InternetAddress> addresses,
    required int ttl,
  }) {
    final records = <_Record>[
      _Record(service, 12, _name(instance)),
      _Record(instance, 33, _srv(port, host)),
      _Record(
        instance,
        16,
        _txt(const [
          'path=/mcp',
          'transport=streamable-http',
          'version=$aiDebugVersion',
        ]),
      ),
      for (final address in addresses)
        if (address.type == InternetAddressType.IPv4)
          _Record(host, 1, address.rawAddress),
      for (final address in addresses)
        if (address.type == InternetAddressType.IPv6)
          _Record(host, 28, address.rawAddress),
    ];
    final out = BytesBuilder(copy: false)
      ..add(_u16(0))
      ..add(_u16(0x8400))
      ..add(_u16(0))
      ..add(_u16(records.length))
      ..add(_u16(0))
      ..add(_u16(0));
    for (final record in records) {
      out
        ..add(_name(record.name))
        ..add(_u16(record.type))
        ..add(_u16(0x8001))
        ..add(_u32(ttl))
        ..add(_u16(record.data.length))
        ..add(record.data);
    }
    return out.takeBytes();
  }

  static Uint8List _name(String name) {
    final out = BytesBuilder(copy: false);
    for (final label in name.split('.').where((part) => part.isNotEmpty)) {
      final bytes = utf8.encode(label);
      if (bytes.length > 63) throw ArgumentError.value(name, 'name');
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    out.addByte(0);
    return out.takeBytes();
  }

  static Uint8List _srv(int port, String host) =>
      Uint8List.fromList([0, 0, 0, 0, ..._u16(port), ..._name(host)]);

  static Uint8List _txt(List<String> values) {
    final out = BytesBuilder(copy: false);
    for (final value in values) {
      final bytes = utf8.encode(value);
      if (bytes.length > 255) throw ArgumentError.value(value, 'value');
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    return out.takeBytes();
  }

  static Uint8List _u16(int value) =>
      Uint8List.fromList([value >> 8 & 0xff, value & 0xff]);

  static Uint8List _u32(int value) => Uint8List.fromList([
    value >> 24 & 0xff,
    value >> 16 & 0xff,
    value >> 8 & 0xff,
    value & 0xff,
  ]);
}

class _Record {
  final String name;
  final int type;
  final Uint8List data;

  const _Record(this.name, this.type, this.data);
}

String _label(String value) {
  final label = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final safe = label.isEmpty ? 'app' : label;
  return safe.length <= 40 ? safe : safe.substring(0, 40);
}

String mdnsHostname(String appId) => '${_label(appId)}-$pid.local.';

Future<List<InternetAddress>> mdnsAddressesFor(
  InternetAddress address, {
  List<NetworkInterface>? interfaces,
}) async {
  if (address.isLoopback) return const [];
  final unspecified = address.rawAddress.every((byte) => byte == 0);
  if (!unspecified) return [address];
  final available =
      interfaces ??
      await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: true,
        type: address.type,
      );
  final out = <InternetAddress>[];
  final seen = <String>{};
  for (final interface in available) {
    for (final candidate in interface.addresses) {
      if (candidate.type != address.type ||
          candidate.isLoopback ||
          candidate.rawAddress.every((byte) => byte == 0) ||
          !seen.add(candidate.address)) {
        continue;
      }
      out.add(candidate);
    }
  }
  return out;
}

bool mdnsQueryMatches(List<int> data, String? instance) {
  if (data.length < 12 || data.length > 4096 || data[2] & 0x80 != 0) {
    return false;
  }
  final text = utf8.decode(data, allowMalformed: true);
  return text.contains('_ai-debug') ||
      (instance != null && text.contains(instance.split('.').first));
}

class MdnsResponseLimiter {
  MdnsResponseLimiter(this.interval) : _lastUs = -interval.inMicroseconds;

  final Duration interval;
  int _lastUs;

  bool take(int nowUs) {
    if (nowUs - _lastUs < interval.inMicroseconds) return false;
    _lastUs = nowUs;
    return true;
  }
}
