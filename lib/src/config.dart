import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'automation/models.dart';

class AiDebugFeatures {
  const AiDebugFeatures({
    this.diagnostics = true,
    this.logs = true,
    this.state = true,
    this.resources = true,
    this.screenshots = false,
    this.automation = false,
    this.navigation = false,
    this.network = false,
    this.files = false,
    this.runtimeControls = false,
    this.telemetry = false,
    this.vmService = false,
    this.isolates = true,
    this.discovery = false,
  });

  const AiDebugFeatures.all({
    this.diagnostics = true,
    this.logs = true,
    this.state = true,
    this.resources = true,
    this.screenshots = true,
    this.automation = true,
    this.navigation = true,
    this.network = true,
    this.files = true,
    this.runtimeControls = true,
    this.telemetry = true,
    this.vmService = true,
    this.isolates = true,
    this.discovery = false,
  });

  const AiDebugFeatures.none({
    this.diagnostics = false,
    this.logs = false,
    this.state = false,
    this.resources = false,
    this.screenshots = false,
    this.automation = false,
    this.navigation = false,
    this.network = false,
    this.files = false,
    this.runtimeControls = false,
    this.telemetry = false,
    this.vmService = false,
    this.isolates = false,
    this.discovery = false,
  });

  final bool diagnostics;
  final bool logs;
  final bool state;
  final bool resources;
  final bool screenshots;
  final bool automation;
  final bool navigation;
  final bool network;
  final bool files;
  final bool runtimeControls;
  final bool telemetry;
  final bool vmService;
  final bool isolates;
  final bool discovery;

  bool sameAs(AiDebugFeatures other) =>
      diagnostics == other.diagnostics &&
      logs == other.logs &&
      state == other.state &&
      resources == other.resources &&
      screenshots == other.screenshots &&
      automation == other.automation &&
      navigation == other.navigation &&
      network == other.network &&
      files == other.files &&
      runtimeControls == other.runtimeControls &&
      telemetry == other.telemetry &&
      vmService == other.vmService &&
      isolates == other.isolates &&
      discovery == other.discovery;
}

class AiDebugConfig {
  AiDebugConfig({
    required this.appId,
    this.bindHost = '127.0.0.1',
    this.port = 9999,
    String? token,
    Set<String> allowedHosts = const {},
    Set<String> allowedOrigins = const {},
    Set<String> allowedFileRoots = const {},
    this.unsafeLan = false,
    this.allowRelease = false,
    this.bodyTimeout = const Duration(seconds: 5),
    this.toolTimeout = const Duration(seconds: 30),
    this.shutdownTimeout = const Duration(seconds: 5),
    this.maxBodyBytes = 1024 * 1024,
    this.maxResultBytes = 4 * 1024 * 1024,
    this.maxQueuedTools = 32,
    this.automation = const UiAutomationConfig(),
    this.features = const AiDebugFeatures(),
  }) : token = token ?? _token(),
       allowedHosts = Set.unmodifiable(allowedHosts),
       allowedOrigins = Set.unmodifiable(allowedOrigins),
       allowedFileRoots = Set.unmodifiable(allowedFileRoots);

  final String appId;
  final String bindHost;
  final int port;
  final String token;
  final Set<String> allowedHosts;
  final Set<String> allowedOrigins;
  final Set<String> allowedFileRoots;
  final bool unsafeLan;
  final bool allowRelease;
  final Duration bodyTimeout;
  final Duration toolTimeout;
  final Duration shutdownTimeout;
  final int maxBodyBytes;
  final int maxResultBytes;
  final int maxQueuedTools;
  final UiAutomationConfig automation;
  final AiDebugFeatures features;

  bool sameAs(AiDebugConfig other) =>
      appId == other.appId &&
      bindHost == other.bindHost &&
      port == other.port &&
      token == other.token &&
      _sameSet(allowedHosts, other.allowedHosts) &&
      _sameSet(allowedOrigins, other.allowedOrigins) &&
      _sameSet(allowedFileRoots, other.allowedFileRoots) &&
      unsafeLan == other.unsafeLan &&
      allowRelease == other.allowRelease &&
      bodyTimeout == other.bodyTimeout &&
      toolTimeout == other.toolTimeout &&
      shutdownTimeout == other.shutdownTimeout &&
      maxBodyBytes == other.maxBodyBytes &&
      maxResultBytes == other.maxResultBytes &&
      maxQueuedTools == other.maxQueuedTools &&
      automation.sameAs(other.automation) &&
      features.sameAs(other.features);

  void validate() {
    if (appId.trim().isEmpty || appId.length > 128) {
      throw ArgumentError.value(
        appId,
        'appId',
        'must contain 1 to 128 characters',
      );
    }
    if (bindHost.trim().isEmpty || bindHost.length > 255) {
      throw ArgumentError.value(
        bindHost,
        'bindHost',
        'must contain 1 to 255 characters',
      );
    }
    if (port < 0 || port > 65535) {
      throw RangeError.range(port, 0, 65535, 'port');
    }
    if (token.isEmpty ||
        token.length > 512 ||
        token.trim() != token ||
        token.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      throw ArgumentError.value(
        token,
        'token',
        'must contain 1 to 512 visible ASCII characters',
      );
    }
    if (unsafeLan && token.length < 32) {
      throw ArgumentError.value(
        token.length,
        'token',
        'must contain at least 32 characters when unsafeLan is enabled',
      );
    }
    if (bodyTimeout <= Duration.zero ||
        bodyTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(
        bodyTimeout,
        'bodyTimeout',
        'must be at most 30 seconds',
      );
    }
    if (toolTimeout <= Duration.zero ||
        toolTimeout > const Duration(minutes: 5)) {
      throw ArgumentError.value(
        toolTimeout,
        'toolTimeout',
        'must be at most 5 minutes',
      );
    }
    if (shutdownTimeout <= Duration.zero ||
        shutdownTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(
        shutdownTimeout,
        'shutdownTimeout',
        'must be at most 30 seconds',
      );
    }
    if (maxBodyBytes < 1 || maxBodyBytes > 16 * 1024 * 1024) {
      throw RangeError.range(maxBodyBytes, 1, 16 * 1024 * 1024, 'maxBodyBytes');
    }
    if (maxResultBytes < 1024 || maxResultBytes > 64 * 1024 * 1024) {
      throw RangeError.range(
        maxResultBytes,
        1024,
        64 * 1024 * 1024,
        'maxResultBytes',
      );
    }
    if (maxQueuedTools < 0 || maxQueuedTools > 1024) {
      throw RangeError.range(maxQueuedTools, 0, 1024, 'maxQueuedTools');
    }
    automation.validate();
    if (features.files && allowedFileRoots.isEmpty) {
      throw ArgumentError(
        'allowedFileRoots is required when files are enabled',
      );
    }
    if (!features.files && allowedFileRoots.isNotEmpty) {
      throw ArgumentError(
        'files must be enabled when allowedFileRoots is configured',
      );
    }
    _validateStrings(allowedHosts, 'allowedHosts', 128, 512);
    _validateStrings(allowedOrigins, 'allowedOrigins', 128, 2048);
    _validateStrings(allowedFileRoots, 'allowedFileRoots', 128, 4096);
    for (final root in allowedFileRoots) {
      if (!Directory(root).isAbsolute) {
        throw ArgumentError.value(root, 'allowedFileRoots', 'must be absolute');
      }
    }
  }
}

void _validateStrings(
  Set<String> values,
  String name,
  int maxItems,
  int maxLength,
) {
  if (values.length > maxItems) {
    throw ArgumentError.value(values.length, name, 'too many values');
  }
  for (final value in values) {
    if (value.isEmpty || value.length > maxLength) {
      throw ArgumentError.value(
        value,
        name,
        'each value must contain 1 to $maxLength characters',
      );
    }
  }
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

String _token() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
