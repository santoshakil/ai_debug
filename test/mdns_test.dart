import 'dart:io';
import 'dart:convert';

import 'package:ai_debug/src/discovery/mdns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mDNS response contains PTR, SRV, TXT, and A records', () {
    final packet = MdnsPacketBuilder.response(
      service: '_ai-debug._tcp.local.',
      instance: 'app-1._ai-debug._tcp.local.',
      host: 'app-1.local.',
      port: 9999,
      addresses: [InternetAddress('192.168.1.2')],
      ttl: 120,
    );

    expect(_u16(packet, 6), 4);
    expect(packet, containsAllInOrder([0x27, 0x0f]));
    expect(packet, containsAllInOrder([192, 168, 1, 2]));
  });

  test('mDNS response writes IPv6 addresses as AAAA records', () {
    final address = InternetAddress('2001:db8::12');
    final packet = MdnsPacketBuilder.response(
      service: '_ai-debug._tcp.local.',
      instance: 'app-1._ai-debug._tcp.local.',
      host: 'app-1.local.',
      port: 9999,
      addresses: [address],
      ttl: 120,
    );

    expect(_u16(packet, 6), 4);
    expect(packet, containsAllInOrder(address.rawAddress));
  });

  test('goodbye response uses zero TTL', () {
    final packet = MdnsPacketBuilder.response(
      service: '_ai-debug._tcp.local.',
      instance: 'app-1._ai-debug._tcp.local.',
      host: 'app-1.local.',
      port: 1,
      addresses: const [],
      ttl: 0,
    );

    expect(packet, containsAllInOrder([0, 0, 0, 0]));
  });

  test('uses only the explicit bound address', () async {
    final address = InternetAddress('192.168.1.50');

    expect(await mdnsAddressesFor(address), [address]);
  });

  test('does not advertise loopback', () async {
    expect(await mdnsAddressesFor(InternetAddress.loopbackIPv4), isEmpty);
  });

  test('wildcard bind advertises reachable matching addresses once', () async {
    final first = InternetAddress('192.168.1.20');
    final second = InternetAddress('10.0.0.2');
    final addresses = await mdnsAddressesFor(
      InternetAddress.anyIPv4,
      interfaces: [
        _Interface([first, InternetAddress.loopbackIPv4, first]),
        _Interface([second, InternetAddress('2001:db8::1')]),
      ],
    );

    expect(addresses, [first, second]);
  });

  test('matches only bounded mDNS queries', () {
    final query = <int>[...List.filled(12, 0), ...utf8.encode('_ai-debug')];
    final response = [...query]..[2] = 0x80;

    expect(mdnsQueryMatches(query, null), isTrue);
    expect(mdnsQueryMatches(response, null), isFalse);
    expect(mdnsQueryMatches(List.filled(4097, 0), null), isFalse);
  });

  test('rate limits query responses', () {
    final limiter = MdnsResponseLimiter(const Duration(milliseconds: 250));

    expect(limiter.take(0), isTrue);
    expect(limiter.take(249999), isFalse);
    expect(limiter.take(250000), isTrue);
  });
}

int _u16(List<int> bytes, int offset) => bytes[offset] << 8 | bytes[offset + 1];

class _Interface implements NetworkInterface {
  _Interface(this.addresses);

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 1;

  @override
  String get name => 'test';
}
