import 'dart:convert';

export 'generated_protocol.dart';
export 'generated_local_protocols.dart';
import 'generated_protocol.dart';
import 'generated_local_protocols.dart';

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
}

/// Validates the generated Cloud ↔ Agent envelope before any message is
/// dispatched. Payload-specific handlers perform their own stricter checks.
class AgentProtocolMessage {
  AgentProtocolMessage._(this.value);

  final Map<String, Object?> value;

  String get type => value['type'] as String;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(value['payload'] as Map);

  static AgentProtocolMessage parse(Object? input) {
    final map = switch (input) {
      String text => _decode(text),
      Map value => Map<String, Object?>.from(value),
      _ => throw const ProtocolException('Agent message must be an object'),
    };
    final encodedSize = utf8.encode(jsonEncode(map)).length;
    if (encodedSize > agentProtocolMaxMessageSizeBytes) {
      throw const ProtocolException('Agent message exceeds the size limit');
    }
    _requiredAgentString(map, 'protocol');
    if (map['protocol'] != agentProtocolName) {
      throw const ProtocolException('unsupported Agent protocol name');
    }
    final version = _requiredAgentString(map, 'protocolVersion');
    if (!isCompatibleVersion(agentProtocolVersion, version)) {
      throw const ProtocolException('unsupported Agent protocol version');
    }
    _requiredAgentString(map, 'messageId');
    final timestamp = DateTime.tryParse(
      _requiredAgentString(map, 'timestamp'),
    );
    if (timestamp == null) {
      throw const ProtocolException('timestamp is invalid');
    }
    final type = _requiredAgentString(map, 'type');
    if (!agentProtocolMessageTypes.contains(type)) {
      throw ProtocolException('unsupported Agent message type: $type');
    }
    if (map['payload'] is! Map) {
      throw const ProtocolException('Agent payload must be an object');
    }
    if (type.startsWith('assignment.')) {
      for (final field in agentProtocolAssignmentEnvelopeFields) {
        _requiredAgentString(map, field);
      }
    }
    return AgentProtocolMessage._(map);
  }

  static Map<String, Object?> _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const ProtocolException('Agent message must be an object');
      }
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      throw const ProtocolException('Agent message is not valid JSON');
    }
  }

  static String _requiredAgentString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw ProtocolException('Agent $key is required');
    }
    return value;
  }
}

class ProtocolEnvelope {
  ProtocolEnvelope({
    required this.messageId,
    required this.goalId,
    required this.runId,
    required this.workerId,
    required this.createdAt,
    required this.messageType,
    required this.payload,
    this.version = protocolVersion,
  });

  final String version;
  final String messageId;
  final String goalId;
  final String runId;
  final String workerId;
  final DateTime createdAt;
  final String messageType;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
        'protocol': protocolName,
        'version': version,
        'messageId': messageId,
        'goalId': goalId,
        'runId': runId,
        'workerId': workerId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'messageType': messageType,
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  static ProtocolEnvelope parse(Object? input) {
    if (input is String) {
      try {
        input = jsonDecode(input);
      } on FormatException {
        throw const ProtocolException('message is not valid JSON');
      }
    }
    if (input is! Map)
      throw const ProtocolException('message must be an object');
    final map = Map<String, Object?>.from(input);
    _requiredString(map, 'protocol');
    if (map['protocol'] != protocolName) {
      throw const ProtocolException('unsupported protocol name');
    }
    final version = _requiredString(map, 'version');
    if (!isCompatibleVersion(protocolVersion, version)) {
      throw const ProtocolException('unsupported protocol version');
    }
    final messageId = _requiredString(map, 'messageId');
    final goalId = _requiredString(map, 'goalId');
    final runId = _requiredString(map, 'runId');
    final workerId = _requiredString(map, 'workerId');
    final messageType = _requiredString(map, 'messageType');
    if (!protocolMessageTypes.contains(messageType)) {
      throw ProtocolException('unsupported message type: $messageType');
    }
    final createdAt = DateTime.tryParse(_requiredString(map, 'createdAt'));
    if (createdAt == null)
      throw const ProtocolException('createdAt is invalid');
    final payload = map['payload'];
    if (payload is! Map)
      throw const ProtocolException('payload must be an object');
    return ProtocolEnvelope(
      version: version,
      messageId: messageId,
      goalId: goalId,
      runId: runId,
      workerId: workerId,
      createdAt: createdAt,
      messageType: messageType,
      payload: Map<String, Object?>.from(payload),
    );
  }

  static String _requiredString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw ProtocolException('$key is required');
    }
    return value;
  }
}

/// Canonical payload validation for repository operations sent to an Agent
/// Worker. The envelope is shared with TypeScript; this validator keeps the
/// operation discriminator and required fields aligned on the Dart side.
class RuntimeOperationRequest {
  RuntimeOperationRequest._(this.envelope, this.operation);

  final ProtocolEnvelope envelope;
  final String operation;

  Map<String, Object?> get payload => envelope.payload;

  static RuntimeOperationRequest parse(ProtocolEnvelope envelope) {
    if (envelope.messageType != 'RuntimeOperationRequest') {
      throw const ProtocolException('message is not a RuntimeOperationRequest');
    }
    final operation = _requiredString(envelope.payload, 'operation');
    _requiredString(envelope.payload, 'taskId');
    final repositoryId = _requiredString(envelope.payload, 'repositoryId');
    _requiredString(envelope.payload, 'revision');
    switch (operation) {
      case 'search':
        _requiredString(envelope.payload, 'query');
        _requiredString(envelope.payload, 'path');
      case 'write_file':
        _requiredString(envelope.payload, 'path');
        _requiredString(envelope.payload, 'content');
      case 'patch_file':
        _requiredString(envelope.payload, 'path');
        final patches = envelope.payload['patches'];
        if (patches is! List || patches.isEmpty) {
          throw const ProtocolException('patches must be a non-empty list');
        }
      case 'delete_file':
        _requiredString(envelope.payload, 'path');
      case 'test':
        final command = envelope.payload['command'];
        final changedFiles = envelope.payload['changedFiles'];
        if (command is! List ||
            command.isEmpty ||
            command.any((item) => item is! String || item.isEmpty)) {
          throw const ProtocolException('command must be a non-empty list');
        }
        if (changedFiles is! List ||
            changedFiles.any((item) => item is! String || item.isEmpty)) {
          throw const ProtocolException('changedFiles must be a string list');
        }
        _requiredString(envelope.payload, 'cwd');
      default:
        throw ProtocolException('unsupported runtime operation: $operation');
    }
    if (repositoryId.isEmpty) {
      throw const ProtocolException('repositoryId is required');
    }
    return RuntimeOperationRequest._(envelope, operation);
  }
}

bool isCompatibleVersion(String local, String remote) {
  final localParts = _versionParts(local);
  final remoteParts = _versionParts(remote);
  return localParts.$1 == remoteParts.$1 && remoteParts.$2 >= localParts.$2;
}

String _requiredString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw ProtocolException('$key is required');
  }
  return value;
}

(int, int, int) _versionParts(String version) {
  final parts = version.split('.').map(int.tryParse).toList();
  if ((parts.length != 2 && parts.length != 3) ||
      parts.any((part) => part == null)) {
    throw const ProtocolException('version must be major.minor.patch');
  }
  return (parts[0]!, parts[1]!, parts.length == 3 ? parts[2]! : 0);
}
