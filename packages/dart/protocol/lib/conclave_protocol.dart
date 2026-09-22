import 'dart:convert';

export 'generated_protocol.dart';
import 'generated_protocol.dart';

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;

  @override
  String toString() => 'ProtocolException: $message';
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

bool isCompatibleVersion(String local, String remote) {
  final localParts = _versionParts(local);
  final remoteParts = _versionParts(remote);
  return localParts.$1 == remoteParts.$1 && remoteParts.$2 >= localParts.$2;
}

(int, int, int) _versionParts(String version) {
  final parts = version.split('.').map(int.tryParse).toList();
  if ((parts.length != 2 && parts.length != 3) ||
      parts.any((part) => part == null)) {
    throw const ProtocolException('version must be major.minor.patch');
  }
  return (parts[0]!, parts[1]!, parts.length == 3 ? parts[2]! : 0);
}
