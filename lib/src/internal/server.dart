import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../discovery/mdns.dart';
import '../log_buffer.dart';
import '../registry.dart';
import '../version.dart';
import 'json_value.dart';
import 'level_codec.dart';

class ServerConfig {
  ServerConfig({
    required this.appId,
    required this.bindHost,
    required this.port,
    required this.token,
    required Set<String> allowedHosts,
    required Set<String> allowedOrigins,
    required this.toolTimeout,
    required this.shutdownTimeout,
    required this.maxBodyBytes,
    required this.maxResultBytes,
    required Iterable<String> allowedFileRoots,
    required this.unsafeLan,
    this.bodyTimeout = const Duration(seconds: 5),
    this.maxQueuedTools = 32,
    this.logsEnabled = true,
    this.maxSessions = 32,
    this.sessionIdleTimeout = const Duration(minutes: 30),
  }) : allowedHosts = Set.unmodifiable(allowedHosts),
       allowedOrigins = Set.unmodifiable(allowedOrigins),
       allowedFileRoots = Set.unmodifiable(allowedFileRoots);

  final String appId;
  final String bindHost;
  final int port;
  final String token;
  final Set<String> allowedHosts;
  final Set<String> allowedOrigins;
  final Duration toolTimeout;
  final Duration shutdownTimeout;
  final int maxBodyBytes;
  final int maxResultBytes;
  final Set<String> allowedFileRoots;
  final bool unsafeLan;
  final Duration bodyTimeout;
  final int maxQueuedTools;
  final bool logsEnabled;
  final int maxSessions;
  final Duration sessionIdleTimeout;

  bool sameAs(ServerConfig other) =>
      appId == other.appId &&
      bindHost == other.bindHost &&
      port == other.port &&
      token == other.token &&
      _sameSet(allowedHosts, other.allowedHosts) &&
      _sameSet(allowedOrigins, other.allowedOrigins) &&
      toolTimeout == other.toolTimeout &&
      shutdownTimeout == other.shutdownTimeout &&
      maxBodyBytes == other.maxBodyBytes &&
      maxResultBytes == other.maxResultBytes &&
      _sameSet(allowedFileRoots, other.allowedFileRoots) &&
      unsafeLan == other.unsafeLan &&
      bodyTimeout == other.bodyTimeout &&
      maxQueuedTools == other.maxQueuedTools &&
      logsEnabled == other.logsEnabled &&
      maxSessions == other.maxSessions &&
      sessionIdleTimeout == other.sessionIdleTimeout;
}

class Server {
  Server({required this.registry, required this.logs});

  static const _modernProtocol = '2026-07-28';
  static const _legacyProtocols = <String>{
    '2025-03-26',
    '2025-06-18',
    '2025-11-25',
  };
  static const _supportedProtocols = <String>[
    _modernProtocol,
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
  ];
  static const _legacyProtocolFallback = '2025-03-26';
  static const _latestProtocol = '2025-11-25';
  static const _builtinTailLogs = 'tail_logs';
  static const _builtinListApps = 'list_apps';
  static final _listAppsSchema = AiDebugSchema.empty();
  static final _tailLogsSchema = AiDebugSchema.object({
    'limit': AiDebugSchema.integer(min: 1, max: 2000, default_: 200),
    'level': AiDebugSchema.string(
      enum_: const ['trace', 'debug', 'info', 'warn', 'error'],
    ),
    'grep': AiDebugSchema.string(),
    'since_ms': AiDebugSchema.integer(),
  });
  static const _mcpAccept = 'application/json, text/event-stream';
  static const _maxActiveRequests = 64;
  static const _initializationTimeout = Duration(minutes: 1);
  static const _dashboard = '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>ai_debug</title><style nonce="ai-debug">
:root{color-scheme:dark;font:14px system-ui;background:#111;color:#eee}body{margin:24px;max-width:1200px}h1{font-size:20px}h2{font-size:16px}small{color:#aaa}form,.buttons{display:flex;gap:8px;margin:12px 0;flex-wrap:wrap}input,button{font:inherit;padding:7px;background:#222;color:#eee;border:1px solid #555;border-radius:5px}input{width:320px}pre{background:#1b1b1b;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap;max-height:420px}.row{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}@media(max-width:700px){.row{display:block}}
</style></head><body><h1>ai_debug</h1><form id="auth"><input id="token" type="password" autocomplete="off" placeholder="access token" required><button>connect</button></form><small id="state">enter the access token</small><div class="row"><section><h2>tools</h2><pre id="tools"></pre></section><section id="logs-panel" hidden><h2>recent logs</h2><pre id="logs"></pre></section><section id="resources-panel" hidden><h2>resources</h2><pre id="resources"></pre></section><section id="frames-panel" hidden><h2>frames</h2><pre id="frames"></pre></section><section id="errors-panel" hidden><h2>errors</h2><pre id="errors"></pre></section><section id="lifecycle-panel" hidden><h2>lifecycle</h2><pre id="lifecycle"></pre></section><section id="states-panel" hidden><h2>state sources</h2><pre id="states"></pre></section><section id="network-panel" hidden><h2>network</h2><pre id="network"></pre></section><section id="routes-panel" hidden><h2>routes</h2><pre id="routes"></pre></section><section id="trace-panel" hidden><h2>trace</h2><pre id="trace"></pre></section><section id="isolates-panel" hidden><h2>isolates</h2><pre id="isolates"></pre></section><section id="ui-panel" hidden><h2>ui snapshot</h2><div class="buttons"><button data-ui="devtools.ui.widgets">widgets</button><button data-ui="devtools.ui.render">render</button><button data-ui="devtools.ui.layers">layers</button><button data-ui="devtools.ui.semantics">semantics</button></div><pre id="ui">select a bounded snapshot</pre></section></div>
<script nonce="ai-debug">const q=s=>document.querySelector(s),panels=[['devtools.resources.status','resources'],['devtools.frames.summary','frames'],['errors.status','errors'],['app.lifecycle','lifecycle'],['state.sources','states'],['network.status','network'],['app.routes','routes'],['devtools.trace.status','trace'],['isolates.status','isolates']],uiArgs={'devtools.ui.widgets':{max_nodes:100,max_depth:8,max_string_length:120},'devtools.ui.render':{max_nodes:100,max_depth:8},'devtools.ui.layers':{max_nodes:100,max_depth:8},'devtools.ui.semantics':{max_nodes:100,max_depth:8,max_string_length:120,settle_timeout_ms:500}};let busy=false,token='',names=[];const headers=()=>({'authorization':'Bearer '+token});async function call(n,a={}){let r=await fetch('/api/cmd/'+encodeURIComponent(n),{method:'POST',headers:{...headers(),'content-type':'application/json'},body:JSON.stringify(a)}),b=await r.json();return b.success?b.result:b}async function tools(){let all=[],cursor;do{let u='/api/tools?limit=100'+(cursor?'&cursor='+encodeURIComponent(cursor):''),r=await fetch(u,{headers:headers()});if(r.status===401)throw Error('invalid access token');if(!r.ok)throw Error('tool list failed');let b=await r.json();all.push(...b.tools);cursor=b.nextCursor}while(cursor);return all}async function load(){if(busy||!token)return;busy=true;try{names=(await tools()).map(x=>x.name);q('#tools').textContent=JSON.stringify(names,null,2);let logs=names.includes('tail_logs');q('#logs-panel').hidden=!logs;if(logs){let l=await fetch('/api/logs?limit=100',{headers:headers()});q('#logs').textContent=JSON.stringify((await l.json()).logs,null,2)}for(let[n,id]of panels){let show=names.includes(n);q('#'+id+'-panel').hidden=!show;if(show)q('#'+id).textContent=JSON.stringify(await call(n),null,2)}let ui=Object.keys(uiArgs).some(n=>names.includes(n));q('#ui-panel').hidden=!ui;for(let b of document.querySelectorAll('[data-ui]'))b.hidden=!names.includes(b.dataset.ui);q('#state').textContent='connected '+new Date().toLocaleTimeString()}catch(e){q('#state').textContent=String(e)}finally{busy=false}}async function inspect(e){let n=e.target.dataset.ui;if(busy||!token||!names.includes(n))return;busy=true;try{q('#ui').textContent=JSON.stringify(await call(n,uiArgs[n]),null,2)}catch(x){q('#ui').textContent=String(x)}finally{busy=false}}q('#auth').addEventListener('submit',e=>{e.preventDefault();token=q('#token').value;q('#token').value='';load()});for(let b of document.querySelectorAll('[data-ui]'))b.addEventListener('click',inspect);setInterval(load,2000)</script></body></html>''';

  final CommandRegistry registry;
  final DartLogBuffer logs;
  final Logger _log = Logger('ai_debug.server');
  final Map<String, _Session> _sessions = {};
  final Set<Future<void>> _requests = {};
  final Random _random = Random.secure();
  _SerialQueue _tools = _SerialQueue();
  _PermitPool _files = _PermitPool(2);
  int _bodyReads = 0;

  HttpServer? _http;
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _sessionTimer;
  ServerConfig? _config;
  ServerConfig? _requestedConfig;
  Future<({String host, int port})>? _startFuture;
  Future<void>? _stopFuture;
  int _generation = 0;
  String? _host;
  int? _port;

  String? get host => _host;
  int? get port => _port;
  bool get isStarted => _http != null;

  Future<({String host, int port})> start(ServerConfig config) {
    final active = _requestedConfig;
    if (active != null && !active.sameAs(config)) {
      throw StateError(
        'ai_debug server already started with different settings',
      );
    }
    final current = _startFuture;
    if (current != null) return current;
    if (_http != null) return Future.value((host: _host!, port: _port!));
    _requestedConfig = config;
    final future = _start(config);
    _startFuture = future;
    return future
        .whenComplete(() {
          if (identical(_startFuture, future)) _startFuture = null;
        })
        .catchError((Object error) {
          if (_http == null) {
            _config = null;
            _requestedConfig = null;
          }
          throw error;
        });
  }

  Future<({String host, int port})> _start(ServerConfig config) async {
    if (config.token.isEmpty) {
      throw ArgumentError.value(config.token, 'token', 'must not be empty');
    }
    if (config.maxBodyBytes < 1) {
      throw RangeError.range(config.maxBodyBytes, 1, null, 'maxBodyBytes');
    }
    if (config.maxResultBytes < 1) {
      throw RangeError.range(config.maxResultBytes, 1, null, 'maxResultBytes');
    }
    if (config.toolTimeout <= Duration.zero ||
        config.bodyTimeout <= Duration.zero ||
        config.shutdownTimeout <= Duration.zero) {
      throw ArgumentError('timeouts must be positive');
    }
    if (config.maxQueuedTools < 0 || config.maxSessions < 1) {
      throw ArgumentError(
        'queue must be non-negative and session limit positive',
      );
    }

    final address = await _resolveAddress(config.bindHost);
    if (!address.isLoopback && utf8.encode(config.token).length < 32) {
      throw StateError('a token of at least 32 UTF-8 bytes is required on LAN');
    }
    if (!address.isLoopback && !config.unsafeLan) {
      throw StateError('set unsafeLan to expose plain HTTP outside loopback');
    }
    final roots = <String>[];
    for (final root in config.allowedFileRoots) {
      final dir = Directory(root);
      if (!dir.isAbsolute) {
        throw ArgumentError.value(root, 'allowedFileRoots', 'must be absolute');
      }
      roots.add(await dir.resolveSymbolicLinks());
    }
    for (final allowed in config.allowedHosts) {
      if (_hostUri(allowed) == null) {
        throw ArgumentError.value(allowed, 'allowedHosts', 'invalid authority');
      }
    }
    final resolved = ServerConfig(
      appId: config.appId,
      bindHost: config.bindHost,
      port: config.port,
      token: config.token,
      allowedHosts: config.allowedHosts,
      allowedOrigins: config.allowedOrigins,
      toolTimeout: config.toolTimeout,
      shutdownTimeout: config.shutdownTimeout,
      maxBodyBytes: config.maxBodyBytes,
      maxResultBytes: config.maxResultBytes,
      allowedFileRoots: roots,
      unsafeLan: config.unsafeLan,
      bodyTimeout: config.bodyTimeout,
      maxQueuedTools: config.maxQueuedTools,
      logsEnabled: config.logsEnabled,
      maxSessions: config.maxSessions,
      sessionIdleTimeout: config.sessionIdleTimeout,
    );
    final http = await HttpServer.bind(address, config.port, shared: false);
    final generation = ++_generation;
    _config = resolved;
    _http = http;
    _host = address.address;
    _port = http.port;
    _subscription = http.listen((req) => _accept(req, generation));
    _sessionTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _expireSessions(),
    );
    _log.info('ai_debug listening on $_host:$_port');
    return (host: _host!, port: _port!);
  }

  Future<void> stop() {
    final current = _stopFuture;
    if (current != null) return current;
    final future = _stop();
    _stopFuture = future;
    return future.whenComplete(() {
      if (identical(_stopFuture, future)) _stopFuture = null;
    });
  }

  Future<void> _stop() async {
    ++_generation;
    final shutdownTimeout =
        _config?.shutdownTimeout ?? const Duration(seconds: 5);
    Object? error;
    StackTrace? stack;
    Future<void> run(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (nextError, nextStack) {
        error ??= nextError;
        stack ??= nextStack;
      }
    }

    _sessionTimer?.cancel();
    _sessionTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final subscriptionDone = subscription?.cancel();
    final tools = _tools;
    final toolsDone = tools.stop();
    final http = _http;
    _http = null;
    if (subscriptionDone != null) await run(() => subscriptionDone);
    if (http != null) {
      try {
        await Future.wait([
          http.close(force: false),
          ..._requests,
        ]).timeout(shutdownTimeout);
      } catch (nextError, nextStack) {
        if (nextError is! TimeoutException) {
          error ??= nextError;
          stack ??= nextStack;
        }
        await run(() => http.close(force: true));
      }
    }
    await run(() => toolsDone);
    _sessions.clear();
    _tools = _SerialQueue();
    _files = _PermitPool(2);
    _config = null;
    _requestedConfig = null;
    _host = null;
    _port = null;
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }

  void _accept(HttpRequest req, int generation) {
    if (_requests.length >= _maxActiveRequests) {
      req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      unawaited(
        _plain(
          req,
          HttpStatus.serviceUnavailable,
          'server is busy',
        ).catchError((_) {}),
      );
      return;
    }
    late final Future<void> task;
    task = _handle(req, generation)
        .catchError((Object error, StackTrace stack) async {
          _log.warning('request failed', error, stack);
          await _tryError(
            req,
            HttpStatus.internalServerError,
            'internal server error',
          );
        })
        .whenComplete(() => _requests.remove(task));
    _requests.add(task);
  }

  Future<void> _handle(HttpRequest req, int generation) async {
    final config = _config;
    if (config == null || generation != _generation) {
      await _plain(req, HttpStatus.serviceUnavailable, 'server stopping');
      return;
    }
    final route = _route(req.uri.path);
    if (route == null) {
      await _plain(req, HttpStatus.notFound, 'not found');
      return;
    }
    if (!_validHost(req, config)) {
      await _json(req, HttpStatus.forbidden, {'error': 'invalid host'});
      return;
    }
    final origin = req.headers.value('origin');
    if (origin != null &&
        !config.allowedOrigins.contains(origin) &&
        !_sameOrigin(req, origin)) {
      await _json(req, HttpStatus.forbidden, {'error': 'invalid origin'});
      return;
    }
    if (origin != null) _applyCors(req.response, origin);
    if (req.method == 'OPTIONS') {
      await _preflight(req, route, origin, config);
      return;
    }
    if (!route.methods.contains(req.method)) {
      req.response.headers.set(
        HttpHeaders.allowHeader,
        route.methods.join(', '),
      );
      await _plain(req, HttpStatus.methodNotAllowed, 'method not allowed');
      return;
    }
    if (route.kind != _RouteKind.health &&
        route.kind != _RouteKind.dashboard &&
        !_authorized(req, config.token)) {
      req.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Bearer realm="ai_debug"',
      );
      await _plain(req, HttpStatus.unauthorized, 'unauthorized');
      return;
    }

    switch (route.kind) {
      case _RouteKind.dashboard:
        await _html(req);
      case _RouteKind.health:
        await _plain(req, HttpStatus.ok, 'ok');
      case _RouteKind.tools:
        await _writeToolList(req, req.uri.queryParametersAll);
      case _RouteKind.logs:
        if (!config.logsEnabled) {
          await _plain(req, HttpStatus.notFound, 'not found');
          return;
        }
        await _writeBoundedJson(
          req,
          _tailLogsHttp(req.uri.queryParameters),
          'log result too large',
        );
      case _RouteKind.command:
        await _handleCommand(req, route.name!);
      case _RouteKind.file:
        await _handleFile(req, config);
      case _RouteKind.mcp:
        await _handleMcp(req, config);
    }
  }

  _Route? _route(String path) {
    if (path == '/' || path == '/dashboard') {
      return const _Route(_RouteKind.dashboard, {'GET'});
    }
    if (path == '/healthz') return const _Route(_RouteKind.health, {'GET'});
    if (path == '/api/tools') return const _Route(_RouteKind.tools, {'GET'});
    if (path == '/api/logs') return const _Route(_RouteKind.logs, {'GET'});
    if (path == '/api/file') {
      return const _Route(_RouteKind.file, {'GET', 'HEAD'});
    }
    if (path == '/mcp') {
      return const _Route(_RouteKind.mcp, {'GET', 'POST', 'DELETE'});
    }
    const prefix = '/api/cmd/';
    if (!path.startsWith(prefix)) return null;
    final encoded = path.substring(prefix.length);
    if (encoded.isEmpty || encoded.contains('/')) return null;
    String name;
    try {
      name = Uri.decodeComponent(encoded);
    } on FormatException {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(name)) return null;
    return _Route(_RouteKind.command, const {'POST'}, name);
  }

  Future<void> _preflight(
    HttpRequest req,
    _Route route,
    String? origin,
    ServerConfig config,
  ) async {
    if (origin == null || !config.allowedOrigins.contains(origin)) {
      await _plain(req, HttpStatus.forbidden, 'origin required');
      return;
    }
    final requested = req.headers.value('access-control-request-method');
    if (requested == null || !route.methods.contains(requested)) {
      await _plain(req, HttpStatus.methodNotAllowed, 'method not allowed');
      return;
    }
    req.response.headers.set(
      'access-control-allow-methods',
      route.methods.join(', '),
    );
    req.response.headers.set(
      'access-control-allow-headers',
      'Authorization, X-AI-Debug-Token, Content-Type, Mcp-Session-Id, '
          'MCP-Protocol-Version, Mcp-Method, Mcp-Name, Last-Event-ID, Range',
    );
    req.response.statusCode = HttpStatus.noContent;
    await req.response.close();
  }

  bool _validHost(HttpRequest req, ServerConfig config) {
    final value = req.headers.value(HttpHeaders.hostHeader);
    if (value == null) return false;
    final host = _host!;
    final advertised = mdnsHostname(config.appId).toLowerCase();
    final allowed = <String>{
      host.toLowerCase(),
      config.bindHost.toLowerCase(),
      advertised,
      advertised.substring(0, advertised.length - 1),
    };
    if (InternetAddress(host).isLoopback) {
      allowed.addAll({'localhost', '127.0.0.1', '::1'});
    }
    final parsed = _hostUri(value);
    if (parsed == null) {
      return false;
    }
    final hasPort = _hasPort(value);
    if (allowed.contains(parsed.host.toLowerCase())) {
      return !hasPort || parsed.port == _port;
    }
    for (final configured in config.allowedHosts) {
      final target = _hostUri(configured);
      if (target == null ||
          target.host.toLowerCase() != parsed.host.toLowerCase()) {
        continue;
      }
      final configuredHasPort = _hasPort(configured);
      if (configuredHasPort) {
        if (hasPort && parsed.port == target.port) return true;
      } else if (!hasPort || parsed.port == _port) {
        return true;
      }
    }
    return false;
  }

  bool _authorized(HttpRequest req, String token) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final candidate = auth != null && auth.toLowerCase().startsWith('bearer ')
        ? auth.substring(7).trim()
        : req.headers.value('x-ai-debug-token')?.trim();
    return candidate != null && _constantEquals(candidate, token);
  }

  void _applyCors(HttpResponse response, String origin) {
    response.headers.set('access-control-allow-origin', origin);
    response.headers.set('vary', 'Origin');
    response.headers.set(
      'access-control-expose-headers',
      'Mcp-Session-Id, Content-Range, Accept-Ranges, ETag',
    );
  }

  Future<void> _handleCommand(HttpRequest req, String name) async {
    if (registry.get(name) == null && !_isBuiltin(name)) {
      await _json(req, HttpStatus.notFound, {'error': 'unknown tool: $name'});
      return;
    }
    Object? raw;
    try {
      raw = await _jsonBody(req);
    } on _HttpError catch (error) {
      await _httpError(req, error);
      return;
    }
    if (raw != null && raw is! Map<String, dynamic>) {
      await _json(req, HttpStatus.badRequest, {
        'error': 'body must be an object',
      });
      return;
    }
    try {
      final result = await _runTool(name, raw as Map<String, dynamic>? ?? {});
      final body = _restResult(_prepareResult(result));
      if (_encodedLength(body) > _config!.maxResultBytes) {
        await _json(req, HttpStatus.requestEntityTooLarge, {
          'success': false,
          'error': 'tool result too large',
        });
        return;
      }
      await _json(req, HttpStatus.ok, body);
    } on _ResultTooLarge {
      await _json(req, HttpStatus.requestEntityTooLarge, {
        'success': false,
        'error': 'tool result too large',
      });
    } on _QueueFull {
      req.response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await _json(req, HttpStatus.tooManyRequests, {
        'success': false,
        'error': 'tool queue full',
      });
    } on TimeoutException {
      await _json(req, HttpStatus.gatewayTimeout, {
        'success': false,
        'error': 'tool timed out',
      });
    } catch (error) {
      await _json(req, HttpStatus.ok, {
        'success': false,
        'error': _safeError(error),
      });
    }
  }

  Future<void> _handleMcp(HttpRequest req, ServerConfig config) async {
    if (req.method == 'GET') {
      req.response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
      await _mcpError(
        req,
        HttpStatus.methodNotAllowed,
        null,
        -32000,
        'SSE is not supported',
      );
      return;
    }
    if (req.method == 'DELETE') {
      final protocol = _singleHeader(req.headers, 'mcp-protocol-version');
      if (protocol != null && !_legacyProtocols.contains(protocol)) {
        req.response.headers.set(HttpHeaders.allowHeader, 'POST');
        await _mcpError(
          req,
          HttpStatus.methodNotAllowed,
          null,
          -32600,
          'Method not allowed',
        );
        return;
      }
      final session = await _session(req, requireVersion: true);
      if (session == null) return;
      _sessions.remove(session.id);
      await _accepted(req);
      return;
    }
    if (!_accepts(req, 'application/json') ||
        !_accepts(req, 'text/event-stream')) {
      await _mcpError(
        req,
        HttpStatus.notAcceptable,
        null,
        -32000,
        'Accept must include $_mcpAccept',
      );
      return;
    }

    Object? raw;
    try {
      raw = await _jsonBody(req);
    } on _HttpError catch (error) {
      await _mcpError(req, error.status, null, error.rpcCode, error.message);
      return;
    }
    if (raw is! Map<String, dynamic>) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        null,
        -32600,
        'Invalid Request',
      );
      return;
    }
    final id = raw['id'];
    final hasId = raw.containsKey('id');
    final modern = _isModernMcp(req, raw);
    if (raw['jsonrpc'] != '2.0' ||
        (hasId && !(modern ? _validModernId(id) : _validId(id)))) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        null,
        -32600,
        'Invalid Request',
      );
      return;
    }
    if (modern) {
      await _handleModernMcp(req, raw, id, hasId, config);
      return;
    }
    final method = raw['method'];
    if (!raw.containsKey('method')) {
      if (!hasId || !_validClientResponse(raw)) {
        await _mcpError(
          req,
          HttpStatus.badRequest,
          null,
          -32600,
          'Invalid Request',
        );
        return;
      }
      final session = await _session(req, requireVersion: true);
      if (session == null) return;
      session.touched = DateTime.now();
      await _accepted(req);
      return;
    }
    if (method is! String) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        hasId ? id : null,
        -32600,
        'Invalid Request',
      );
      return;
    }
    if (raw.containsKey('result') || raw.containsKey('error')) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        hasId ? id : null,
        -32600,
        'Invalid Request',
      );
      return;
    }

    if (method == 'initialize') {
      await _initialize(req, raw, id, hasId, config);
      return;
    }
    final session = await _session(req, requireVersion: true);
    if (session == null) return;
    session.touched = DateTime.now();

    if (!hasId) {
      if (method == 'notifications/initialized' &&
          session.state == _SessionState.awaitingInitialized) {
        session.state = _SessionState.ready;
      }
      await _accepted(req);
      return;
    }
    if (session.inFlight.contains(id)) {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32600,
        'request id is already in flight',
      );
      return;
    }
    if (session.state != _SessionState.ready && method != 'ping') {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32600,
        'session is not initialized',
      );
      return;
    }
    session.inFlight.add(id);
    try {
      switch (method) {
        case 'ping':
          await _mcpResult(req, id, const <String, Object?>{});
        case 'tools/list':
          await _writeMcpToolList(req, id, raw['params']);
        case 'tools/call':
          await _mcpCall(req, id, raw['params']);
        default:
          await _mcpError(req, HttpStatus.ok, id, -32601, 'Method not found');
      }
    } finally {
      session.inFlight.remove(id);
    }
  }

  bool _isModernMcp(HttpRequest req, Map<String, dynamic> message) {
    final params = message['params'];
    final meta = params is Map<String, dynamic> ? params['_meta'] : null;
    final bodyVersion = meta is Map<String, dynamic>
        ? meta['io.modelcontextprotocol/protocolVersion']
        : null;
    if (bodyVersion is String && !_legacyProtocols.contains(bodyVersion)) {
      return true;
    }
    final header = _singleHeader(req.headers, 'mcp-protocol-version');
    return header != null && !_legacyProtocols.contains(header);
  }

  Future<void> _handleModernMcp(
    HttpRequest req,
    Map<String, dynamic> message,
    Object? id,
    bool hasId,
    ServerConfig config,
  ) async {
    final method = message['method'];
    final params = message['params'];
    if (!hasId ||
        method is! String ||
        params is! Map<String, dynamic> ||
        message.containsKey('result') ||
        message.containsKey('error')) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        hasId ? id : null,
        -32600,
        'Invalid Request',
      );
      return;
    }
    final meta = params['_meta'];
    final version = meta is Map<String, dynamic>
        ? meta['io.modelcontextprotocol/protocolVersion']
        : null;
    final capabilities = meta is Map<String, dynamic>
        ? meta['io.modelcontextprotocol/clientCapabilities']
        : null;
    final clientInfo = meta is Map<String, dynamic>
        ? meta['io.modelcontextprotocol/clientInfo']
        : null;
    if (meta is! Map<String, dynamic> ||
        version is! String ||
        version.isEmpty ||
        version.length > 64 ||
        capabilities is! Map<String, dynamic> ||
        (clientInfo != null && !_validImplementation(clientInfo))) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        id,
        -32602,
        'Invalid request metadata',
      );
      return;
    }
    final protocolHeader = _singleHeader(req.headers, 'mcp-protocol-version');
    final methodHeader = _singleHeader(req.headers, 'mcp-method');
    if (protocolHeader != version || methodHeader != method) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        id,
        -32020,
        'Header mismatch',
      );
      return;
    }
    if (version != _modernProtocol) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        id,
        -32022,
        'Unsupported protocol version',
        data: {'supported': _supportedProtocols, 'requested': version},
      );
      return;
    }

    switch (method) {
      case 'server/discover':
        if (params.keys.any((key) => key != '_meta')) {
          await _mcpError(
            req,
            HttpStatus.ok,
            id,
            -32602,
            'Invalid discover params',
          );
          return;
        }
        await _mcpResult(req, id, {
          'supportedVersions': const [_modernProtocol],
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'instructions':
              'Read and drive the running ${config.appId} Flutter app.',
          'ttlMs': 300000,
          'cacheScope': 'private',
        }, modern: true);
      case 'ping':
        if (params.keys.any((key) => key != '_meta')) {
          await _mcpError(
            req,
            HttpStatus.ok,
            id,
            -32602,
            'Invalid ping params',
          );
          return;
        }
        await _mcpResult(req, id, const <String, Object?>{}, modern: true);
      case 'tools/list':
        await _writeMcpToolList(req, id, params, modern: true);
      case 'tools/call':
        final name = params['name'];
        final header = _decodeMcpHeader(_singleHeader(req.headers, 'mcp-name'));
        if (name is! String || header != name) {
          await _mcpError(
            req,
            HttpStatus.badRequest,
            id,
            -32020,
            'Header mismatch',
          );
          return;
        }
        await _mcpCall(req, id, params, modern: true);
      default:
        await _mcpError(
          req,
          HttpStatus.notFound,
          id,
          -32601,
          'Method not found',
        );
    }
  }

  Future<void> _initialize(
    HttpRequest req,
    Map<String, dynamic> message,
    Object? id,
    bool hasId,
    ServerConfig config,
  ) async {
    if (!hasId || req.headers.value('mcp-session-id') != null) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        null,
        -32600,
        'Invalid initialize request',
      );
      return;
    }
    final params = message['params'];
    final clientInfo = params is Map<String, dynamic>
        ? params['clientInfo']
        : null;
    if (params is! Map<String, dynamic> ||
        params['protocolVersion'] is! String ||
        params['capabilities'] is! Map ||
        clientInfo is! Map<String, dynamic> ||
        (params['protocolVersion'] as String).isEmpty ||
        (params['protocolVersion'] as String).length > 64 ||
        clientInfo['name'] is! String ||
        clientInfo['version'] is! String ||
        (clientInfo['name'] as String).isEmpty ||
        (clientInfo['name'] as String).length > 256 ||
        (clientInfo['version'] as String).isEmpty ||
        (clientInfo['version'] as String).length > 256) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        id,
        -32602,
        'Invalid initialize params',
      );
      return;
    }
    final requested = params['protocolVersion'] as String;
    final selected = _legacyProtocols.contains(requested)
        ? requested
        : _latestProtocol;
    _expireSessions();
    if (_sessions.length >= config.maxSessions) {
      _evictOldestUninitialized();
    }
    if (_sessions.length >= config.maxSessions) {
      await _mcpError(
        req,
        HttpStatus.serviceUnavailable,
        id,
        -32000,
        'Too many sessions',
      );
      return;
    }
    final session = _Session(_sessionId(), selected);
    _sessions[session.id] = session;
    req.response.headers.set('mcp-session-id', session.id);
    await _mcpResult(req, id, {
      'protocolVersion': selected,
      'serverInfo': {'name': 'ai_debug', 'version': aiDebugVersion},
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'instructions': 'Read and drive the running ${config.appId} Flutter app.',
    });
  }

  Future<_Session?> _session(
    HttpRequest req, {
    required bool requireVersion,
  }) async {
    final id = req.headers.value('mcp-session-id');
    if (id == null) {
      await _mcpError(
        req,
        HttpStatus.badRequest,
        null,
        -32000,
        'Mcp-Session-Id is required',
      );
      return null;
    }
    final session = _sessions[id];
    if (session == null) {
      await _mcpError(
        req,
        HttpStatus.notFound,
        null,
        -32001,
        'Session not found',
      );
      return null;
    }
    if (requireVersion) {
      final version =
          req.headers.value('mcp-protocol-version') ?? _legacyProtocolFallback;
      if (!_legacyProtocols.contains(version) || version != session.protocol) {
        await _mcpError(
          req,
          HttpStatus.badRequest,
          null,
          -32000,
          'Invalid MCP-Protocol-Version',
        );
        return null;
      }
    }
    return session;
  }

  Future<void> _mcpCall(
    HttpRequest req,
    Object? id,
    Object? rawParams, {
    bool modern = false,
  }) async {
    if (rawParams is! Map<String, dynamic> || rawParams['name'] is! String) {
      await _mcpError(req, HttpStatus.ok, id, -32602, 'Invalid tool params');
      return;
    }
    final name = rawParams['name'] as String;
    if (!_isBuiltin(name) && registry.get(name) == null) {
      await _mcpError(req, HttpStatus.ok, id, -32602, 'Unknown tool: $name');
      return;
    }
    final args = rawParams['arguments'];
    if (args != null && args is! Map<String, dynamic>) {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32602,
        'Tool arguments must be an object',
      );
      return;
    }
    try {
      final result = await _runTool(name, args as Map<String, dynamic>? ?? {});
      final body = _toolResult(_prepareResult(result), modern: modern);
      if (_encodedLength(body) > _config!.maxResultBytes) {
        await _mcpResult(
          req,
          id,
          _toolError('tool result too large'),
          modern: modern,
        );
        return;
      }
      await _mcpResult(req, id, body, modern: modern);
    } on _ResultTooLarge {
      await _mcpResult(
        req,
        id,
        _toolError('tool result too large'),
        modern: modern,
      );
    } on _QueueFull {
      await _mcpResult(req, id, _toolError('tool queue full'), modern: modern);
    } on TimeoutException {
      await _mcpResult(req, id, _toolError('tool timed out'), modern: modern);
    } on AiDebugSchemaError catch (error) {
      await _mcpError(req, HttpStatus.ok, id, -32602, error.message);
    } catch (error) {
      await _mcpResult(req, id, _toolError(_safeError(error)), modern: modern);
    }
  }

  Future<AiDebugResult> _runTool(String name, Map<String, dynamic> args) {
    final config = _config!;
    return _tools.run(
      () => _dispatch(name, args),
      timeout: config.toolTimeout,
      maxQueued: config.maxQueuedTools,
    );
  }

  _PreparedResult _prepareResult(AiDebugResult result) {
    final config = _config!;
    final binary = result.binary;
    if (binary != null &&
        _base64Length(binary.length) + 1024 > config.maxResultBytes) {
      throw const _ResultTooLarge();
    }
    try {
      return _PreparedResult(
        json: toJsonValue(
          result.json,
          maxDepth: 32,
          maxItems: 10000,
          maxStringLength: 65536,
          maxStringUnits: max(1, config.maxResultBytes ~/ 2),
          truncate: false,
        ),
        binary: binary,
        mime: result.binaryMime ?? 'application/octet-stream',
      );
    } on JsonValueLimitException {
      throw const _ResultTooLarge();
    }
  }

  Map<String, Object?> _restResult(_PreparedResult result) => {
    'success': true,
    'result': result.json,
    if (result.binary != null) 'binary_b64': base64Encode(result.binary!),
    if (result.binary != null) 'binary_mime': result.mime,
  };

  Map<String, Object?> _toolResult(
    _PreparedResult result, {
    bool modern = false,
  }) {
    final content = <Map<String, Object?>>[];
    if (result.binary != null) {
      final mime = result.mime;
      if (mime.startsWith('image/')) {
        content.add({
          'type': 'image',
          'data': base64Encode(result.binary!),
          'mimeType': mime,
        });
      } else if (mime.startsWith('audio/')) {
        content.add({
          'type': 'audio',
          'data': base64Encode(result.binary!),
          'mimeType': mime,
        });
      } else {
        content.add({
          'type': 'resource',
          'resource': {
            'uri': 'ai-debug://tool-result',
            'mimeType': mime,
            'blob': base64Encode(result.binary!),
          },
        });
      }
    }
    final value = result.json;
    if (value != null) {
      content.add({
        'type': 'text',
        'text': value is String ? value : jsonEncode(value),
      });
    }
    return {
      'content': content,
      if (modern && result.binary == null)
        'structuredContent': value
      else if (value is Map<String, dynamic>)
        'structuredContent': value,
      'isError': false,
    };
  }

  Map<String, Object?> _toolError(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };

  Future<void> _writeToolList(
    HttpRequest req,
    Map<String, List<String>> query,
  ) async {
    try {
      final rawLimit = _one(query, 'limit');
      final limit = rawLimit == null ? 100 : int.parse(rawLimit);
      if (limit < 1 || limit > 500) throw const FormatException();
      final start = _decodeCursor(_one(query, 'cursor'));
      await _jsonBytes(
        req,
        HttpStatus.ok,
        _toolListBytes(includeStreaming: true, start: start, limit: limit),
      );
    } on FormatException {
      await _json(req, HttpStatus.badRequest, {
        'error': 'invalid tool list cursor or limit',
      });
    } on _ResultTooLarge {
      await _json(req, HttpStatus.requestEntityTooLarge, {
        'error': 'tool inventory too large',
      });
    }
  }

  Future<void> _writeMcpToolList(
    HttpRequest req,
    Object? id,
    Object? rawParams, {
    bool modern = false,
  }) async {
    if (rawParams != null && rawParams is! Map<String, dynamic>) {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32602,
        'Invalid tool list params',
      );
      return;
    }
    try {
      final params = rawParams as Map<String, dynamic>?;
      if (params != null &&
          (params.keys.any(
                (key) => key != 'cursor' && !(modern && key == '_meta'),
              ) ||
              (params['cursor'] != null && params['cursor'] is! String))) {
        throw const FormatException();
      }
      final start = _decodeCursor(params?['cursor'] as String?);
      await _jsonBytes(
        req,
        HttpStatus.ok,
        _toolListBytes(
          includeStreaming: false,
          start: start,
          limit: 100,
          id: id,
          modern: modern,
        ),
      );
    } on FormatException {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32602,
        'Invalid tool list cursor',
      );
    } on _ResultTooLarge {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32000,
        'Tool inventory exceeds maxResultBytes',
      );
    }
  }

  Uint8List _toolListBytes({
    required bool includeStreaming,
    required int start,
    required int limit,
    Object? id,
    bool modern = false,
  }) {
    final maxBytes = _config!.maxResultBytes;
    final reserve = modern ? 128 : 64;
    final prefix = id == null
        ? utf8.encode('{"tools":[')
        : <int>[
            ...utf8.encode('{"jsonrpc":"2.0","id":'),
            ..._encodeJson(id, maxBytes),
            ...utf8.encode(
              modern
                  ? ',"result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"ai_debug","version":"$aiDebugVersion"}},"tools":['
                  : ',"result":{"tools":[',
            ),
          ];
    final out = BytesBuilder(copy: false);
    if (prefix.length + reserve > maxBytes) throw const _ResultTooLarge();
    out.add(prefix);
    final iterator = _toolSpecs(includeStreaming: includeStreaming).iterator;
    for (var skipped = 0; skipped < start; skipped++) {
      if (!iterator.moveNext()) break;
    }
    var count = 0;
    var more = false;
    while (count < limit && iterator.moveNext()) {
      final comma = count == 0 ? 0 : 1;
      final available = maxBytes - out.length - comma - reserve;
      try {
        final bytes = _encodeJson(iterator.current, available);
        if (comma != 0) out.addByte(0x2c);
        out.add(bytes);
        count++;
      } on _ResultTooLarge {
        if (count == 0) rethrow;
        more = true;
        break;
      }
    }
    if (!more && count == limit) more = iterator.moveNext();
    final next = more ? _encodeCursor(start + count) : null;
    final suffix = utf8.encode(
      id == null
          ? next == null
                ? ']}'
                : '],"nextCursor":"$next"}'
          : next == null
          ? modern
                ? '],"ttlMs":300000,"cacheScope":"private"}}'
                : ']}}'
          : modern
          ? '],"nextCursor":"$next","ttlMs":300000,"cacheScope":"private"}}'
          : '],"nextCursor":"$next"}}',
    );
    if (out.length + suffix.length > maxBytes) {
      throw const _ResultTooLarge();
    }
    out.add(suffix);
    return out.takeBytes();
  }

  Iterable<Map<String, Object?>> _toolSpecs({
    required bool includeStreaming,
  }) sync* {
    final builtins = _builtinTools()
      ..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));
    final custom = registry.all;
    var builtin = 0;
    var tool = 0;
    while (builtin < builtins.length || tool < custom.length) {
      final useBuiltin =
          builtin < builtins.length &&
          (tool >= custom.length ||
              (builtins[builtin]['name']! as String).compareTo(
                    custom[tool].name,
                  ) <
                  0);
      if (useBuiltin) {
        final value = builtins[builtin++];
        yield includeStreaming ? {...value, 'streaming': false} : value;
        continue;
      }
      final value = custom[tool++];
      yield {
        'name': value.name,
        if (value.title != null) 'title': value.title,
        'description': value.description,
        'inputSchema': value.inputSchema.asJson,
        if (value.outputSchema != null)
          'outputSchema': value.outputSchema!.asJson,
        if (value.annotations != null) 'annotations': value.annotations,
        if (includeStreaming) 'streaming': false,
      };
    }
  }

  List<Map<String, Object?>> _builtinTools() => [
    {
      'name': _builtinListApps,
      'description': 'List the app instance served by this server.',
      'inputSchema': _listAppsSchema.asJson,
    },
    if (_config?.logsEnabled == true)
      {
        'name': _builtinTailLogs,
        'description': 'Return a Dart log tail, newest last.',
        'inputSchema': _tailLogsSchema.asJson,
      },
  ];

  bool _isBuiltin(String name) =>
      name == _builtinListApps ||
      (name == _builtinTailLogs && _config?.logsEnabled == true);

  Future<AiDebugResult> _dispatch(
    String name,
    Map<String, dynamic> args,
  ) async {
    if (name == _builtinTailLogs && _config?.logsEnabled == true) {
      _tailLogsSchema.validate(args);
      return AiDebugResult.json(_tailLogs(args));
    }
    if (name == _builtinListApps) {
      _listAppsSchema.validate(args);
      return AiDebugResult.json({
        'apps': [
          {'appId': _config!.appId, 'host': _host, 'port': _port},
        ],
      });
    }
    return registry.dispatch(name, args);
  }

  Map<String, Object?> _tailLogsHttp(Map<String, String> query) {
    try {
      return _tailLogs({
        if (query['limit'] != null) 'limit': int.parse(query['limit']!),
        if (query['level'] != null) 'level': query['level'],
        if (query['grep'] != null) 'grep': query['grep'],
        if (query['since_ms'] != null)
          'since_ms': int.parse(query['since_ms']!),
      });
    } on FormatException {
      return const {'logs': <Object>[]};
    }
  }

  Map<String, Object?> _tailLogs(Map<String, dynamic> args) {
    final limit = (args['limit'] is int ? args['limit'] as int : 200).clamp(
      1,
      2000,
    );
    final level = args['level'];
    final min = level is String ? parseLoggingLevel(level) : null;
    final grep = args['grep'] as String?;
    final sinceMs = args['since_ms'] as int?;
    final since = sinceMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(sinceMs);
    final out = <Map<String, Object?>>[
      for (final record in logs.tail(
        limit: limit,
        minLevel: min,
        grep: grep,
        since: since,
      ))
        {
          'timestamp_ms': record.time.millisecondsSinceEpoch,
          'source': 'dart',
          'level': loggingLevelToStr(record.level),
          'logger': record.loggerName,
          'message': record.message,
          if (record.error != null) 'error': record.error,
          if (record.stackTrace != null) 'stack': record.stackTrace,
        },
    ];
    return {'logs': out.reversed.toList(growable: false)};
  }

  Future<Object?> _jsonBody(HttpRequest req) async {
    final type = req.headers.contentType;
    if (type == null || type.mimeType.toLowerCase() != 'application/json') {
      throw const _HttpError(
        HttpStatus.unsupportedMediaType,
        -32000,
        'Content-Type must be application/json',
      );
    }
    final config = _config!;
    if (req.contentLength > config.maxBodyBytes) {
      throw const _HttpError(
        HttpStatus.requestEntityTooLarge,
        -32000,
        'request body too large',
      );
    }
    if (_bodyReads >= 8) {
      throw const _HttpError(
        HttpStatus.tooManyRequests,
        -32000,
        'too many request bodies',
      );
    }
    _bodyReads++;
    final iterator = StreamIterator<List<int>>(req);
    final elapsed = Stopwatch()..start();
    final bytes = BytesBuilder(copy: false);
    var cancelAfterResponse = false;
    try {
      while (true) {
        final remaining = config.bodyTimeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          cancelAfterResponse = true;
          throw const _HttpError(
            HttpStatus.requestTimeout,
            -32000,
            'request body timed out',
          );
        }
        final hasChunk = await iterator.moveNext().timeout(
          remaining,
          onTimeout: () {
            cancelAfterResponse = true;
            throw const _HttpError(
              HttpStatus.requestTimeout,
              -32000,
              'request body timed out',
            );
          },
        );
        if (!hasChunk) break;
        final chunk = iterator.current;
        bytes.add(chunk);
        if (bytes.length > config.maxBodyBytes) {
          cancelAfterResponse = true;
          throw const _HttpError(
            HttpStatus.requestEntityTooLarge,
            -32000,
            'request body too large',
          );
        }
      }
    } finally {
      if (cancelAfterResponse) {
        unawaited(_cancelAfterResponse(req.response, iterator));
      } else {
        await iterator.cancel();
      }
      _bodyReads--;
    }
    final data = bytes.takeBytes();
    if (data.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(data));
    } on FormatException {
      throw const _HttpError(HttpStatus.badRequest, -32700, 'Parse error');
    }
  }

  Future<void> _handleFile(HttpRequest req, ServerConfig config) async {
    if (config.allowedFileRoots.isEmpty) {
      await _plain(req, HttpStatus.notFound, 'file service disabled');
      return;
    }
    final paths = req.uri.queryParametersAll['path'];
    if (paths == null || paths.length != 1 || paths.single.isEmpty) {
      await _plain(req, HttpStatus.badRequest, 'exactly one path is required');
      return;
    }
    final file = File(paths.single);
    if (!file.isAbsolute || file.path.contains('\u0000')) {
      await _plain(req, HttpStatus.badRequest, 'path must be absolute');
      return;
    }
    String resolved;
    FileStat stat;
    try {
      resolved = await file.resolveSymbolicLinks();
      stat = await File(resolved).stat();
    } on FileSystemException {
      await _plain(req, HttpStatus.notFound, 'file not found');
      return;
    }
    if (stat.type != FileSystemEntityType.file ||
        !_insideRoots(resolved, config.allowedFileRoots)) {
      await _plain(req, HttpStatus.forbidden, 'file is outside allowed roots');
      return;
    }
    final total = stat.size;
    final etag =
        'W/"${stat.modified.millisecondsSinceEpoch.toRadixString(16)}-${total.toRadixString(16)}"';
    req.response.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.etagHeader, etag)
      ..set(HttpHeaders.lastModifiedHeader, HttpDate.format(stat.modified))
      ..set('cache-control', 'no-store')
      ..set('x-content-type-options', 'nosniff')
      ..set(
        'content-disposition',
        _contentDisposition(File(resolved).uri.pathSegments.last),
      );
    final rangeValue = req.headers.value(HttpHeaders.rangeHeader);
    if (rangeValue == null && total > config.maxResultBytes) {
      req.response.headers
        ..set(HttpHeaders.contentRangeHeader, 'bytes */$total')
        ..set(HttpHeaders.contentLengthHeader, 0);
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await req.response.close();
      return;
    }
    var start = 0;
    var end = total - 1;
    if (rangeValue != null) {
      final range = _parseRange(rangeValue, total);
      if (range == null) {
        req.response.headers
          ..set(HttpHeaders.contentRangeHeader, 'bytes */$total')
          ..set(HttpHeaders.contentLengthHeader, 0);
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await req.response.close();
        return;
      }
      start = range.$1;
      end = range.$2;
      if (end - start + 1 > config.maxResultBytes) {
        req.response.headers
          ..set(HttpHeaders.contentRangeHeader, 'bytes */$total')
          ..set(HttpHeaders.contentLengthHeader, 0);
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers
        ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total')
        ..set(HttpHeaders.contentLengthHeader, end - start + 1);
    } else {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(HttpHeaders.contentLengthHeader, total);
    }
    if (req.method == 'HEAD') {
      await req.response.close();
      return;
    }
    final files = _files;
    if (!files.tryAcquire()) {
      req.response.headers
        ..removeAll(HttpHeaders.contentLengthHeader)
        ..set(HttpHeaders.retryAfterHeader, '1');
      await _plain(
        req,
        HttpStatus.tooManyRequests,
        'file stream limit reached',
      );
      return;
    }
    try {
      await req.response.addStream(File(resolved).openRead(start, end + 1));
      await req.response.close();
    } finally {
      files.release();
    }
  }

  (int, int)? _parseRange(String value, int total) {
    if (total == 0 || !value.startsWith('bytes=') || value.contains(',')) {
      return null;
    }
    final parts = value.substring(6).split('-');
    if (parts.length != 2) return null;
    if (parts.first.isEmpty) {
      final count = int.tryParse(parts.last);
      if (count == null || count <= 0) return null;
      return ((total - count).clamp(0, total - 1), total - 1);
    }
    final start = int.tryParse(parts.first);
    if (start == null || start < 0 || start >= total) return null;
    if (parts.last.isEmpty) return (start, total - 1);
    final rawEnd = int.tryParse(parts.last);
    if (rawEnd == null || rawEnd < start) return null;
    return (start, rawEnd.clamp(start, total - 1));
  }

  Future<void> _html(HttpRequest req) async {
    final bytes = utf8.encode(_dashboard);
    req.response.headers
      ..contentType = ContentType.html
      ..contentLength = bytes.length
      ..set(
        'content-security-policy',
        "default-src 'none'; script-src 'nonce-ai-debug'; style-src 'nonce-ai-debug'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      )
      ..set('x-content-type-options', 'nosniff')
      ..set('referrer-policy', 'no-referrer')
      ..set('cache-control', 'no-store');
    req.response.statusCode = HttpStatus.ok;
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _mcpResult(
    HttpRequest req,
    Object? id,
    Object? result, {
    bool modern = false,
  }) async {
    final body = modern
        ? {
            if (result is Map<String, Object?>) ...result,
            'resultType': 'complete',
            '_meta': {
              'io.modelcontextprotocol/serverInfo': {
                'name': 'ai_debug',
                'version': aiDebugVersion,
              },
            },
          }
        : result;
    try {
      await _jsonBytes(
        req,
        HttpStatus.ok,
        _encodeJson({
          'jsonrpc': '2.0',
          'id': id,
          'result': body,
        }, _config!.maxResultBytes),
      );
    } on _ResultTooLarge {
      await _mcpError(
        req,
        HttpStatus.ok,
        id,
        -32000,
        'Result exceeds maxResultBytes',
      );
    }
  }

  Future<void> _mcpError(
    HttpRequest req,
    int status,
    Object? id,
    int code,
    String message, {
    Object? data,
  }) async {
    final body = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message, 'data': ?data},
    };
    try {
      await _jsonBytes(req, status, _encodeJson(body, _config?.maxResultBytes));
    } on _ResultTooLarge {
      body['id'] = null;
      await _json(req, status, body);
    }
  }

  Future<void> _httpError(HttpRequest req, _HttpError error) =>
      _json(req, error.status, {'error': error.message});

  Future<void> _accepted(HttpRequest req) async {
    req.response
      ..statusCode = HttpStatus.accepted
      ..headers.contentLength = 0;
    await req.response.close();
  }

  Future<void> _plain(HttpRequest req, int status, String body) async {
    final bytes = utf8.encode(body);
    if (status == HttpStatus.requestTimeout ||
        status == HttpStatus.requestEntityTooLarge) {
      req.response.persistentConnection = false;
    }
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..headers.contentLength = bytes.length
      ..add(bytes);
    await req.response.close();
  }

  Future<void> _json(HttpRequest req, int status, Object? body) async {
    await _jsonBytes(req, status, _encodeJson(body));
  }

  Future<void> _writeBoundedJson(
    HttpRequest req,
    Object? body,
    String message,
  ) async {
    try {
      await _jsonBytes(
        req,
        HttpStatus.ok,
        _encodeJson(body, _config!.maxResultBytes),
      );
    } on _ResultTooLarge {
      await _json(req, HttpStatus.requestEntityTooLarge, {'error': message});
    }
  }

  Future<void> _jsonBytes(HttpRequest req, int status, List<int> bytes) async {
    if (status == HttpStatus.requestTimeout ||
        status == HttpStatus.requestEntityTooLarge) {
      req.response.persistentConnection = false;
    }
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.contentLength = bytes.length
      ..headers.set('cache-control', 'no-store')
      ..add(bytes);
    await req.response.close();
  }

  Uint8List _encodeJson(Object? body, [int? maxBytes]) {
    final limit = maxBytes;
    if (limit != null && limit < 1) throw const _ResultTooLarge();
    final out = BytesBuilder(copy: false);
    late final ByteConversionSink sink;
    sink = ByteConversionSink.withCallback((bytes) => out.add(bytes));
    final encoder = JsonUtf8Encoder(null, null, 256);
    final input = encoder.startChunkedConversion(
      _BoundedByteSink(sink, limit ?? 0x7fffffffffffffff),
    );
    try {
      input
        ..add(body)
        ..close();
    } on _ResultTooLarge {
      rethrow;
    }
    return out.takeBytes();
  }

  Future<void> _tryError(HttpRequest req, int status, String message) async {
    try {
      await _plain(req, status, message);
    } catch (_) {}
  }

  void _expireSessions() {
    final config = _config;
    if (config == null) return;
    final cutoff = DateTime.now().subtract(config.sessionIdleTimeout);
    final initializingCutoff = DateTime.now().subtract(
      config.sessionIdleTimeout < _initializationTimeout
          ? config.sessionIdleTimeout
          : _initializationTimeout,
    );
    _sessions.removeWhere(
      (_, session) =>
          session.touched.isBefore(cutoff) ||
          (session.state == _SessionState.awaitingInitialized &&
              session.created.isBefore(initializingCutoff)),
    );
  }

  void _evictOldestUninitialized() {
    _Session? oldest;
    for (final session in _sessions.values) {
      if (session.state != _SessionState.awaitingInitialized) continue;
      if (oldest == null || session.created.isBefore(oldest.created)) {
        oldest = session;
      }
    }
    if (oldest != null) _sessions.remove(oldest.id);
  }

  String _sessionId() {
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  int _encodedLength(Object? value) => utf8.encode(jsonEncode(value)).length;

  Future<InternetAddress> _resolveAddress(String host) async {
    final direct = InternetAddress.tryParse(host);
    if (direct != null) return direct;
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw SocketException('host did not resolve');
    }
    if (host.toLowerCase() == 'localhost') {
      return addresses.firstWhere(
        (address) => address.type == InternetAddressType.IPv4,
        orElse: () => addresses.first,
      );
    }
    if (addresses.length != 1) {
      throw StateError('bindHost must resolve to one address');
    }
    return addresses.single;
  }
}

enum _RouteKind { dashboard, health, tools, logs, command, file, mcp }

class _Route {
  const _Route(this.kind, this.methods, [this.name]);
  final _RouteKind kind;
  final Set<String> methods;
  final String? name;
}

enum _SessionState { awaitingInitialized, ready }

class _Session {
  _Session(this.id, this.protocol)
    : created = DateTime.now(),
      touched = DateTime.now();
  final String id;
  final String protocol;
  final Set<Object?> inFlight = {};
  final DateTime created;
  DateTime touched;
  _SessionState state = _SessionState.awaitingInitialized;
}

class _SerialQueue {
  final List<_QueuedTool<dynamic>> _queue = [];
  Future<void>? _draining;
  var _accepting = true;

  Future<T> run<T>(
    Future<T> Function() call, {
    required Duration timeout,
    required int maxQueued,
  }) {
    if (!_accepting) throw StateError('server stopped');
    if (_draining != null && _queue.length >= maxQueued) {
      throw const _QueueFull();
    }
    final job = _QueuedTool<T>(call, timeout);
    _queue.add(job);
    _startDrain();
    return job.result.future;
  }

  Future<void> stop() {
    _accepting = false;
    for (final job in _queue) {
      job.fail(StateError('server stopped'));
    }
    _queue.clear();
    return _draining ?? Future.value();
  }

  void _startDrain() {
    if (_draining != null) return;
    late final Future<void> future;
    future = _drain().whenComplete(() {
      if (identical(_draining, future)) _draining = null;
    });
    _draining = future;
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      await job.run();
    }
  }
}

class _PermitPool {
  _PermitPool(this.limit);

  final int limit;
  int _used = 0;

  bool tryAcquire() {
    if (_used >= limit) return false;
    _used++;
    return true;
  }

  void release() {
    _used--;
  }
}

class _QueuedTool<T> {
  _QueuedTool(this.call, this.timeout) {
    _timer = Timer(timeout, () {
      _expired = true;
      if (!result.isCompleted) {
        result.completeError(TimeoutException('tool timed out', timeout));
      }
    });
  }
  final Future<T> Function() call;
  final Duration timeout;
  final Completer<T> result = Completer<T>();
  late final Timer _timer;
  var _expired = false;

  Future<void> run() async {
    if (_expired) return;
    late final Future<T> future;
    try {
      future = call();
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
      _timer.cancel();
      return;
    }
    try {
      final value = await future;
      if (!result.isCompleted) result.complete(value);
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    } finally {
      _timer.cancel();
    }
  }

  void fail(Object error) {
    _timer.cancel();
    if (!result.isCompleted) result.completeError(error);
  }
}

class _QueueFull implements Exception {
  const _QueueFull();
}

class _ResultTooLarge implements Exception {
  const _ResultTooLarge();
}

class _PreparedResult {
  const _PreparedResult({
    required this.json,
    required this.binary,
    required this.mime,
  });

  final Object? json;
  final Uint8List? binary;
  final String mime;
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this._sink, this._limit);

  final Sink<List<int>> _sink;
  final int _limit;
  int _length = 0;

  @override
  void add(List<int> data) {
    _length += data.length;
    if (_length > _limit) throw const _ResultTooLarge();
    _sink.add(data);
  }

  @override
  void close() => _sink.close();
}

class _HttpError implements Exception {
  const _HttpError(this.status, this.rpcCode, this.message);
  final int status;
  final int rpcCode;
  final String message;
}

bool _validId(Object? value) =>
    (value is String && value.length <= 256) ||
    (value is num && value.isFinite);

bool _validModernId(Object? value) =>
    (value is String && value.length <= 256) || value is int;

bool _validImplementation(Object? value) =>
    value is Map<String, dynamic> &&
    value['name'] is String &&
    (value['name'] as String).isNotEmpty &&
    (value['name'] as String).length <= 256 &&
    value['version'] is String &&
    (value['version'] as String).isNotEmpty &&
    (value['version'] as String).length <= 256;

String? _decodeMcpHeader(String? value) {
  if (value == null) return null;
  if (!value.startsWith('=?base64?') || !value.endsWith('?=')) {
    if (value.isEmpty ||
        value.trim() != value ||
        value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      return null;
    }
    return value;
  }
  final encoded = value.substring(9, value.length - 2);
  if (encoded.isEmpty) return null;
  try {
    final bytes = base64Decode(encoded);
    if (base64Encode(bytes) != encoded) return null;
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

String? _singleHeader(HttpHeaders headers, String name) {
  final values = headers[name];
  return values != null && values.length == 1 ? values.single : null;
}

String? _one(Map<String, List<String>> query, String name) {
  final values = query[name];
  if (values == null) return null;
  if (values.length != 1 || values.single.isEmpty) {
    throw const FormatException();
  }
  return values.single;
}

String _encodeCursor(int value) =>
    base64UrlEncode(utf8.encode('$value')).replaceAll('=', '');

int _decodeCursor(String? value) {
  if (value == null) return 0;
  if (value.length > 32) throw const FormatException();
  try {
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    final text = utf8.decode(base64Url.decode(padded));
    final cursor = int.parse(text);
    if (cursor < 0 || _encodeCursor(cursor) != value) {
      throw const FormatException();
    }
    return cursor;
  } on ArgumentError {
    throw const FormatException();
  }
}

bool _accepts(HttpRequest req, String mime) {
  final value = req.headers.value(HttpHeaders.acceptHeader);
  if (value == null) return false;
  return value
      .split(',')
      .any((part) => part.split(';').first.trim().toLowerCase() == mime);
}

Uri? _hostUri(String value) {
  final uri = Uri.tryParse('http://$value');
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  try {
    if (_hasPort(value) && (uri.port < 1 || uri.port > 65535)) return null;
  } on FormatException {
    return null;
  }
  return uri;
}

bool _hasPort(String value) => value.startsWith('[')
    ? value.contains(']:')
    : value.lastIndexOf(':') > 0 &&
          value.indexOf(':') == value.lastIndexOf(':');

bool _sameOrigin(HttpRequest req, String origin) {
  final uri = Uri.tryParse(origin);
  final host = req.headers.value(HttpHeaders.hostHeader);
  if (uri == null || host == null || uri.scheme != 'http') return false;
  return uri.authority.toLowerCase() == host.toLowerCase();
}

Future<void> _cancelAfterResponse(
  HttpResponse response,
  StreamIterator<List<int>> iterator,
) async {
  try {
    await response.done;
  } catch (_) {}
  try {
    await iterator.cancel();
  } catch (_) {}
}

bool _validClientResponse(Map<String, dynamic> message) {
  final hasResult = message.containsKey('result');
  final hasError = message.containsKey('error');
  if (hasResult == hasError) return false;
  if (!hasError) return true;
  final error = message['error'];
  return error is Map && error['code'] is int && error['message'] is String;
}

bool _constantEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var diff = a.length ^ b.length;
  final length = max(1, max(a.length, b.length));
  for (var i = 0; i < length; i++) {
    final av = a.isEmpty ? 0 : a[i % a.length];
    final bv = b.isEmpty ? 0 : b[i % b.length];
    diff |= av ^ bv;
  }
  return diff == 0;
}

int _base64Length(int bytes) => ((bytes + 2) ~/ 3) * 4;

bool _insideRoots(String path, Iterable<String> roots) {
  final separator = Platform.pathSeparator;
  return roots.any(
    (root) =>
        path == root ||
        path.startsWith(root.endsWith(separator) ? root : '$root$separator'),
  );
}

String _contentDisposition(String name) {
  final fallback = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return "attachment; filename=\"$fallback\"; filename*=UTF-8''${Uri.encodeComponent(name)}";
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

String _safeError(Object error) {
  try {
    final message = error.toString();
    return message.length <= 4096 ? message : '${message.substring(0, 4095)}…';
  } catch (_) {
    return '<unavailable>';
  }
}
