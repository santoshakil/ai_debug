import 'dart:io';

import '../registry.dart';

void registerNetworkTools(CommandRegistry registry) {
  registry.add(
    ToolEntry(
      name: 'network.interfaces',
      description: 'Network interfaces visible to the app process.',
      inputSchema: AiDebugSchema.empty(),
      annotations: _readOnly,
      handler: (_) async {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          includeLinkLocal: true,
        );
        return {
          'interfaces': [
            for (final interface in interfaces.take(128))
              {
                'name': _cut(interface.name, 256),
                'index': interface.index,
                'addresses': [
                  for (final address in interface.addresses.take(128))
                    {
                      'address': address.address,
                      'type': address.type == InternetAddressType.IPv4
                          ? 'ipv4'
                          : 'ipv6',
                      'linkLocal': address.isLinkLocal,
                    },
                ],
                'addressesTruncated': interface.addresses.length > 128,
              },
          ],
          'truncated': interfaces.length > 128,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'network.resolve',
      description: 'Resolve one hostname from the app process.',
      inputSchema: AiDebugSchema.object(
        {
          'host': AiDebugSchema.string(minLength: 1, maxLength: 255),
          'timeoutMs': AiDebugSchema.integer(
            min: 100,
            max: 30000,
            default_: 5000,
          ),
        },
        required: ['host'],
      ),
      annotations: _openWorld,
      handler: (args) async {
        final host = args['host'] as String;
        final timeout = Duration(
          milliseconds: args['timeoutMs'] as int? ?? 5000,
        );
        final stopwatch = Stopwatch()..start();
        final addresses = await InternetAddress.lookup(host).timeout(timeout);
        return {
          'durationMs': stopwatch.elapsedMicroseconds / 1000,
          'addresses': [
            for (final address in addresses.take(64)) address.address,
          ],
          'truncated': addresses.length > 64,
        };
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'network.connect',
      description: 'Test one TCP connection from the app process.',
      inputSchema: AiDebugSchema.object(
        {
          'host': AiDebugSchema.string(minLength: 1, maxLength: 255),
          'port': AiDebugSchema.integer(min: 1, max: 65535),
          'timeoutMs': AiDebugSchema.integer(
            min: 100,
            max: 30000,
            default_: 3000,
          ),
        },
        required: ['host', 'port'],
      ),
      annotations: _openWorld,
      handler: (args) async {
        final stopwatch = Stopwatch()..start();
        final socket = await Socket.connect(
          args['host'] as String,
          args['port'] as int,
          timeout: Duration(milliseconds: args['timeoutMs'] as int? ?? 3000),
        );
        try {
          return {
            'remoteAddress': socket.remoteAddress.address,
            'remotePort': socket.remotePort,
            'durationMs': stopwatch.elapsedMicroseconds / 1000,
          };
        } finally {
          socket.destroy();
        }
      },
    ),
  );
  registry.add(
    ToolEntry(
      name: 'network.http_probe',
      description: 'Perform a bounded HTTP HEAD request from the app process.',
      inputSchema: AiDebugSchema.object(
        {
          'url': AiDebugSchema.string(minLength: 1, maxLength: 4096),
          'timeoutMs': AiDebugSchema.integer(
            min: 100,
            max: 30000,
            default_: 5000,
          ),
        },
        required: ['url'],
      ),
      annotations: _openWorld,
      handler: (args) async {
        final uri = Uri.parse(args['url'] as String);
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          throw ArgumentError.value(uri, 'url', 'must use HTTP or HTTPS');
        }
        if (uri.userInfo.isNotEmpty) {
          throw ArgumentError.value(uri, 'url', 'credentials are not allowed');
        }
        final timeout = Duration(
          milliseconds: args['timeoutMs'] as int? ?? 5000,
        );
        final client = HttpClient()..connectionTimeout = timeout;
        final stopwatch = Stopwatch()..start();
        try {
          final request = await client.headUrl(uri).timeout(timeout);
          request.followRedirects = false;
          final response = await request.close().timeout(timeout);
          return {
            'status': response.statusCode,
            'durationMs': stopwatch.elapsedMicroseconds / 1000,
            'contentLength': response.contentLength,
            'redirect': _cut(
              response.headers.value(HttpHeaders.locationHeader),
              2048,
            ),
          };
        } finally {
          client.close(force: true);
        }
      },
    ),
  );
}

String? _cut(String? value, int max) => value == null || value.length <= max
    ? value
    : '${value.substring(0, max - 1)}…';

const _readOnly = <String, Object?>{
  'readOnlyHint': true,
  'openWorldHint': false,
};

const _openWorld = <String, Object?>{
  'readOnlyHint': false,
  'destructiveHint': false,
  'openWorldHint': true,
};
