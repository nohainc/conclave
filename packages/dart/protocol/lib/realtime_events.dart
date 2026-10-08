import 'dart:convert';

import 'conclave_protocol.dart';

class RealtimeEvent {
  RealtimeEvent._(this.value);

  final Map<String, Object?> value;

  String get eventId => value['eventId']! as String;
  String get type => value['type']! as String;
  String get version => value['version']! as String;
  String? get workspaceId => value['workspaceId'] as String?;
  Map<String, Object?> get stream => value['stream'] is Map
      ? Map<String, Object?>.from(value['stream'] as Map)
      : {'kind': 'execution_workspace', 'id': workspaceId};
  String get streamKey => jsonEncode([stream['kind'], stream['id']]);
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
        !isCompatibleVersion('1.0', version)) {
      throw ProtocolException('unsupported realtime event version: $version');
    }
    if (DateTime.tryParse(_requiredString(decoded, 'timestamp')) == null) {
      throw const ProtocolException('Realtime event timestamp is invalid');
    }
    final rawStream = decoded['stream'];
    if (rawStream != null) {
      if (rawStream is! Map ||
          rawStream.keys.any((key) => key != 'kind' && key != 'id')) {
        throw const ProtocolException('Realtime stream is invalid');
      }
      final stream = Map<String, Object?>.from(rawStream);
      final kind = _requiredString(stream, 'kind');
      final streamId = _requiredString(stream, 'id');
      if (!realtimeStreamKinds.contains(kind)) {
        throw const ProtocolException('Realtime stream kind is invalid');
      }
      if (kind == 'execution_workspace') {
        if (_requiredString(decoded, 'workspaceId') != streamId) {
          throw const ProtocolException(
              'Execution stream must match workspaceId');
        }
      } else {
        if (decoded.containsKey('workspaceId') || version == '1.0') {
          throw const ProtocolException(
              'Synchronization streams require 1.1 and no workspaceId');
        }
        if (kind == 'space' && decoded['spaceId'] != streamId) {
          throw const ProtocolException('Space stream must match spaceId');
        }
      }
    } else {
      _requiredString(decoded, 'workspaceId');
    }
    if (decoded['sequence'] is! int || (decoded['sequence'] as int) < 0) {
      throw const ProtocolException('Realtime event sequence is invalid');
    }
    final payload = decoded['payload'];
    if (payload is! Map) {
      throw const ProtocolException('Realtime event payload must be an object');
    }
    if (collaborationRealtimeEventTypes.contains(decoded['type'])) {
      if (rawStream is! Map || rawStream['kind'] == 'execution_workspace') {
        throw const ProtocolException(
            'Collaboration requires a synchronization stream');
      }
      _requiredString(decoded, 'spaceId');
      _requiredString(Map<String, Object?>.from(payload), 'entityId');
      if (payload.keys.any((key) => key != 'entityId' && key != 'threadId')) {
        throw const ProtocolException(
            'Collaboration payloads contain identifiers only');
      }
      if ((decoded['type'] as String).startsWith('thread.') ||
          (decoded['type'] as String).startsWith('discussion.')) {
        if (_requiredString(decoded, 'threadId') != payload['threadId']) {
          throw const ProtocolException('Thread signal identity mismatch');
        }
      }
    } else if ((durableRealtimeEventTypes.contains(decoded['type']) ||
            ephemeralRealtimeEventTypes.contains(decoded['type'])) &&
        decoded['workspaceId'] == null) {
      throw const ProtocolException('Execution events require workspaceId');
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
      'workerId',
      'workRequestId',
      'threadId',
      'stepKind',
      'leaseId',
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
