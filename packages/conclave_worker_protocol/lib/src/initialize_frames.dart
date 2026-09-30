import 'dart:convert';

import 'limits.dart';
import 'protocol_version.dart';

abstract class WorkerFrame {
  const WorkerFrame({required this.requestId});

  final String requestId;
  String get type;
  Map<String, Object?> toJson();

  String encode() {
    final json = jsonEncode(toJson());
    if (utf8.encode(json).length > WorkerProtocolLimits.maxFrameBytes) {
      throw const FormatException('Worker frame exceeds the byte limit');
    }
    return json;
  }
}

final class InitializeRequest extends WorkerFrame {
  InitializeRequest({
    required String requestId,
    required this.workerTypeId,
    required this.expectedWorkerVersion,
    this.protocolVersion = localWorkerProtocolVersion,
  }) : super(requestId: requestId) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      workerTypeId,
      'workerTypeId',
      WorkerProtocolLimits.maxWorkerTypeIdLength,
    );
    _validateToken(
      expectedWorkerVersion,
      'expectedWorkerVersion',
      WorkerProtocolLimits.maxWorkerVersionLength,
    );
    _validateProtocol(protocolVersion);
  }

  final String protocolVersion;
  final String workerTypeId;
  final String expectedWorkerVersion;

  @override
  String get type => 'initialize.request';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'protocolVersion': protocolVersion,
    'requestId': requestId,
    'workerTypeId': workerTypeId,
    'expectedWorkerVersion': expectedWorkerVersion,
  };

  factory InitializeRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'workerTypeId',
      'expectedWorkerVersion',
    });
    _checkType(json, 'initialize.request');
    final protocol = _requiredString(json, 'protocolVersion');
    if (protocol != localWorkerProtocolVersion) {
      throw FormatException('unsupported protocol version: $protocol');
    }
    return InitializeRequest(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      protocolVersion: protocol,
      workerTypeId: _boundedString(
        json,
        'workerTypeId',
        WorkerProtocolLimits.maxWorkerTypeIdLength,
      ),
      expectedWorkerVersion: _boundedString(
        json,
        'expectedWorkerVersion',
        WorkerProtocolLimits.maxWorkerVersionLength,
      ),
    );
  }
}

final class InitializeResult extends WorkerFrame {
  InitializeResult({
    required super.requestId,
    required this.workerTypeId,
    required this.workerVersion,
    required this.stateSchemaVersion,
    required Iterable<String> capabilities,
    this.protocolVersion = localWorkerProtocolVersion,
  }) : capabilities = List.unmodifiable(capabilities) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      workerTypeId,
      'workerTypeId',
      WorkerProtocolLimits.maxWorkerTypeIdLength,
    );
    _validateToken(
      workerVersion,
      'workerVersion',
      WorkerProtocolLimits.maxWorkerVersionLength,
    );
    _validateProtocol(protocolVersion);
    if (stateSchemaVersion < 1 ||
        stateSchemaVersion > WorkerProtocolLimits.maxStateSchemaVersion) {
      throw const FormatException('stateSchemaVersion is out of range');
    }
    if (this.capabilities.length > WorkerProtocolLimits.maxCapabilities) {
      throw const FormatException('too many Worker capabilities');
    }
    if (this.capabilities.toSet().length != this.capabilities.length) {
      throw const FormatException('capabilities must not contain duplicates');
    }
    for (final capability in this.capabilities) {
      _validateToken(
        capability,
        'capability',
        WorkerProtocolLimits.maxCapabilityLength,
      );
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(capability)) {
        throw const FormatException(
          'capability must be a stable lowercase identifier',
        );
      }
    }
  }

  final String protocolVersion;
  final String workerTypeId;
  final String workerVersion;
  final int stateSchemaVersion;
  final List<String> capabilities;

  @override
  String get type => 'initialize.result';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'protocolVersion': protocolVersion,
    'requestId': requestId,
    'workerTypeId': workerTypeId,
    'workerVersion': workerVersion,
    'stateSchemaVersion': stateSchemaVersion,
    'capabilities': capabilities,
  };

  factory InitializeResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'workerTypeId',
      'workerVersion',
      'stateSchemaVersion',
      'capabilities',
    });
    _checkType(json, 'initialize.result');
    final protocol = _requiredString(json, 'protocolVersion');
    if (protocol != localWorkerProtocolVersion) {
      throw FormatException('unsupported protocol version: $protocol');
    }
    final rawSchemaVersion = json['stateSchemaVersion'];
    if (rawSchemaVersion is! int) {
      throw const FormatException('stateSchemaVersion must be an integer');
    }
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List ||
        rawCapabilities.length > WorkerProtocolLimits.maxCapabilities) {
      throw const FormatException('capabilities must be a bounded array');
    }
    if (rawCapabilities.any((value) => value is! String)) {
      throw const FormatException('capabilities must contain only strings');
    }
    return InitializeResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      protocolVersion: protocol,
      workerTypeId: _boundedString(
        json,
        'workerTypeId',
        WorkerProtocolLimits.maxWorkerTypeIdLength,
      ),
      workerVersion: _boundedString(
        json,
        'workerVersion',
        WorkerProtocolLimits.maxWorkerVersionLength,
      ),
      stateSchemaVersion: rawSchemaVersion,
      capabilities: rawCapabilities.cast<String>(),
    );
  }
}

void _checkType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected)
    throw FormatException('expected $expected frame');
}

void _expectKeys(Map<String, Object?> json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('frame contains unsupported field: ${unknown.first}');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String _boundedString(Map<String, Object?> json, String key, int limit) {
  final value = _requiredString(json, key);
  _validateToken(value, key, limit);
  return value;
}

void _validateToken(String value, String name, int limit) {
  if (value.trim().isEmpty || value.length > limit) {
    throw FormatException('$name is empty or exceeds $limit characters');
  }
}

void _validateProtocol(String value) {
  if (value != localWorkerProtocolVersion) {
    throw FormatException('unsupported protocol version: $value');
  }
}
