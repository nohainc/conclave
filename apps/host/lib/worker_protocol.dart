import 'dart:collection';
import 'package:conclave_protocol/conclave_protocol.dart' as protocol;

const workerProtocolVersion = protocol.workerProtocolVersion;

const workerMethods = protocol.workerProtocolMethods;

const workerNotifications = protocol.workerProtocolNotifications;

class WorkerProtocolViolation implements Exception {
  const WorkerProtocolViolation(this.message);
  final String message;

  @override
  String toString() => 'WorkerProtocolViolation: $message';
}

class WorkerRpcResponse {
  const WorkerRpcResponse({required this.id, this.result, this.error});

  final String id;
  final Map<String, Object?>? result;
  final Map<String, Object?>? error;

  factory WorkerRpcResponse.parse(Object? raw) {
    if (raw is! Map) {
      throw const WorkerProtocolViolation(
          'JSON-RPC response must be an object');
    }
    final map = Map<String, Object?>.from(raw);
    if (map['jsonrpc'] != protocol.workerProtocolJsonRpcVersion) {
      throw const WorkerProtocolViolation('JSON-RPC version must be 2.0');
    }
    final id = map['id'];
    if (id is! String || id.isEmpty) {
      throw const WorkerProtocolViolation('response id is required');
    }
    final hasResult = map['result'] != null;
    final hasError = map['error'] != null;
    if (hasResult == hasError) {
      throw const WorkerProtocolViolation(
          'response must contain result or error');
    }
    if (hasResult && map['result'] is! Map) {
      throw const WorkerProtocolViolation('response result must be an object');
    }
    if (hasError && map['error'] is! Map) {
      throw const WorkerProtocolViolation('response error must be an object');
    }
    return WorkerRpcResponse(
      id: id,
      result:
          hasResult ? Map<String, Object?>.from(map['result'] as Map) : null,
      error: hasError ? Map<String, Object?>.from(map['error'] as Map) : null,
    );
  }
}

class WorkerRpcNotification {
  const WorkerRpcNotification({required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;

  factory WorkerRpcNotification.parse(Object? raw) {
    if (raw is! Map) {
      throw const WorkerProtocolViolation('notification must be an object');
    }
    final map = Map<String, Object?>.from(raw);
    if (map['jsonrpc'] != protocol.workerProtocolJsonRpcVersion ||
        map['id'] != null) {
      throw const WorkerProtocolViolation('invalid JSON-RPC notification');
    }
    final method = map['method'];
    final params = map['params'];
    if (method is! String || !workerNotifications.contains(method)) {
      throw WorkerProtocolViolation('unsupported worker notification: $method');
    }
    if (params != null && params is! Map) {
      throw const WorkerProtocolViolation(
          'notification params must be an object');
    }
    return WorkerRpcNotification(
      method: method,
      params: params == null
          ? <String, Object?>{}
          : Map<String, Object?>.from(params as Map),
    );
  }
}

class WorkerIdentity {
  const WorkerIdentity(
      {required this.workerId,
      required this.version,
      required this.protocolVersion,
      required this.runtimeLanguage,
      required this.capabilities});

  final String workerId;
  final String version;
  final String protocolVersion;
  final String runtimeLanguage;
  final UnmodifiableSetView<String> capabilities;

  factory WorkerIdentity.parse(Map<String, Object?> result) {
    String required(String key) {
      final value = result[key];
      if (value is! String || value.isEmpty) {
        throw WorkerProtocolViolation('initialize result requires $key');
      }
      return value;
    }

    final capabilities = result['capabilities'];
    if (capabilities is! List ||
        capabilities.any((value) => value is! String || value.isEmpty)) {
      throw const WorkerProtocolViolation(
          'initialize capabilities must be a string list');
    }
    return WorkerIdentity(
      workerId: required('workerId'),
      version: required('version'),
      protocolVersion: required('protocolVersion'),
      runtimeLanguage: required('runtimeLanguage'),
      capabilities:
          UnmodifiableSetView(Set<String>.from(capabilities.cast<String>())),
    );
  }
}
