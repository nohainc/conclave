import 'dart:collection';
import 'package:conclave_protocol/conclave_protocol.dart';

const pluginProtocolVersion = workerPluginProtocolVersion;

const pluginMethods = workerPluginMethods;

const pluginNotifications = workerPluginNotifications;

class PluginProtocolViolation implements Exception {
  const PluginProtocolViolation(this.message);
  final String message;

  @override
  String toString() => 'PluginProtocolViolation: $message';
}

class PluginRpcResponse {
  const PluginRpcResponse({required this.id, this.result, this.error});

  final String id;
  final Map<String, Object?>? result;
  final Map<String, Object?>? error;

  factory PluginRpcResponse.parse(Object? raw) {
    if (raw is! Map) {
      throw const PluginProtocolViolation(
          'JSON-RPC response must be an object');
    }
    final map = Map<String, Object?>.from(raw);
    if (map['jsonrpc'] != workerPluginJsonRpcVersion) {
      throw const PluginProtocolViolation('JSON-RPC version must be 2.0');
    }
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const PluginProtocolViolation('response id is required');
    }
    final hasResult = map['result'] != null;
    final hasError = map['error'] != null;
    if (hasResult == hasError) {
      throw const PluginProtocolViolation(
          'response must contain result or error');
    }
    if (hasResult && map['result'] is! Map) {
      throw const PluginProtocolViolation('response result must be an object');
    }
    if (hasError && map['error'] is! Map) {
      throw const PluginProtocolViolation('response error must be an object');
    }
    return PluginRpcResponse(
      id: id,
      result:
          hasResult ? Map<String, Object?>.from(map['result'] as Map) : null,
      error: hasError ? Map<String, Object?>.from(map['error'] as Map) : null,
    );
  }
}

class PluginRpcNotification {
  const PluginRpcNotification({required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;

  factory PluginRpcNotification.parse(Object? raw) {
    if (raw is! Map) {
      throw const PluginProtocolViolation('notification must be an object');
    }
    final map = Map<String, Object?>.from(raw);
    if (map['jsonrpc'] != workerPluginJsonRpcVersion || map['id'] != null) {
      throw const PluginProtocolViolation('invalid JSON-RPC notification');
    }
    final method = map['method'];
    final params = map['params'];
    if (method is! String || !pluginNotifications.contains(method)) {
      throw PluginProtocolViolation('unsupported plugin notification: $method');
    }
    if (params != null && params is! Map) {
      throw const PluginProtocolViolation(
          'notification params must be an object');
    }
    return PluginRpcNotification(
      method: method,
      params: params == null
          ? <String, Object?>{}
          : Map<String, Object?>.from(params as Map),
    );
  }
}

class PluginIdentity {
  const PluginIdentity(
      {required this.pluginId,
      required this.version,
      required this.protocolVersion,
      required this.runtimeLanguage,
      required this.capabilities});

  final String pluginId;
  final String version;
  final String protocolVersion;
  final String runtimeLanguage;
  final UnmodifiableSetView<String> capabilities;

  factory PluginIdentity.parse(Map<String, Object?> result) {
    String required(String key) {
      final value = result[key];
      if (value is! String || value.isEmpty) {
        throw PluginProtocolViolation('initialize result requires $key');
      }
      return value;
    }

    final capabilities = result['capabilities'];
    if (capabilities is! List ||
        capabilities.any((value) => value is! String || value.isEmpty)) {
      throw const PluginProtocolViolation(
          'initialize capabilities must be a string list');
    }
    return PluginIdentity(
      pluginId: required('pluginId'),
      version: required('version'),
      protocolVersion: required('protocolVersion'),
      runtimeLanguage: required('runtimeLanguage'),
      capabilities:
          UnmodifiableSetView(Set<String>.from(capabilities.cast<String>())),
    );
  }
}
