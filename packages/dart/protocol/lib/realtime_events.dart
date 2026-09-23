import 'dart:convert';

import 'conclave_protocol.dart';

class RealtimeEvent {
  RealtimeEvent._(this.value);

  final Map<String, Object?> value;

  String get eventId => value['eventId']! as String;
  String get type => value['type']! as String;
  String get version => value['version']! as String;
  String get workspaceId => value['workspaceId']! as String;
  int get sequence => value['sequence']! as int;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(value['payload']! as Map);

  Map<String, Object?> toJson() => Map<String, Object?>.from(value);
  String encode() => jsonEncode(value);

  static RealtimeEvent parse(Object? input) {
    final decoded = switch (input) {
      String text => _decode(text),
      Map value => Map<String, Object?>.from(value),
      _ => throw const ProtocolException('Realtime event must be an object'),
    };
    for (final key in const [
      'eventId',
      'type',
      'version',
      'timestamp',
      'workspaceId',
      'sequence',
      'payload',
    ]) {
      if (!decoded.containsKey(key)) {
        throw ProtocolException('Realtime event $key is required');
      }
    }
    _requiredString(decoded, 'eventId');
    _requiredString(decoded, 'type');
    final version = _requiredString(decoded, 'version');
    if (!RegExp(r'^\d+\.\d+$').hasMatch(version) ||
        !isCompatibleVersion(realtimeEventsVersion, version)) {
      throw ProtocolException('unsupported realtime event version: $version');
    }
    if (DateTime.tryParse(_requiredString(decoded, 'timestamp')) == null) {
      throw const ProtocolException('Realtime event timestamp is invalid');
    }
    _requiredString(decoded, 'workspaceId');
    if (decoded['sequence'] is! int || (decoded['sequence'] as int) < 0) {
      throw const ProtocolException('Realtime event sequence is invalid');
    }
    final payload = decoded['payload'];
    if (payload is! Map) {
      throw const ProtocolException('Realtime event payload must be an object');
    }
    const allowedPayloadFields = {
      'entityId',
      'status',
      'message',
      'summary',
      'text',
      'delta',
      'tool',
      'artifactId',
      'findingId',
      'verificationId',
      'hostId',
      'workerId',
      'credentialProfileId',
      'percentage',
      'durationMs',
      'tokenCount',
      'coalesced',
    };
    if (payload.keys.any((key) => !allowedPayloadFields.contains(key))) {
      throw const ProtocolException(
          'Realtime event payload contains an unsupported or secret field');
    }
    if ((payload['delta'] is String &&
            (payload['delta'] as String).length > 8192) ||
        (payload['text'] is String &&
            (payload['text'] as String).length > 32768)) {
      throw const ProtocolException('Realtime event payload is too large');
    }
    return RealtimeEvent._(decoded);
  }

  static Map<String, Object?> _decode(String text) {
    try {
      final value = jsonDecode(text);
      if (value is! Map) {
        throw const ProtocolException('Realtime event must be an object');
      }
      return Map<String, Object?>.from(value);
    } on FormatException {
      throw const ProtocolException('Realtime event is not valid JSON');
    }
  }

  static String _requiredString(Map<String, Object?> value, String key) {
    final item = value[key];
    if (item is! String || item.trim().isEmpty) {
      throw ProtocolException('Realtime event $key is required');
    }
    return item;
  }
}
