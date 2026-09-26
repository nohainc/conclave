import 'dart:convert';

const v7AdapterProtocolVersion = '1.0';
const v7AdapterMaxFrameBytes = 1024 * 1024;

/// Parses one newline-delimited V7 adapter response and rejects unknown fields.
Map<String, Object?> parseV7AdapterFrame(String frame) {
  if (utf8.encode(frame).length > v7AdapterMaxFrameBytes) {
    throw const FormatException('adapter frame exceeds the 1 MB limit');
  }
  final decoded = jsonDecode(frame);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('adapter frame must be an object');
  }
  final value = Map<String, Object?>.from(decoded);
  final type = value['type'];
  if (value['protocolVersion'] != v7AdapterProtocolVersion || type is! String) {
    throw const FormatException('adapter protocol version or type is invalid');
  }
  final (allowed, optional) = switch (type) {
    'initialize.result' => (
        {
          'type',
          'protocolVersion',
          'requestId',
          'adapterVersion',
          'capabilities'
        },
        <String>{},
      ),
    'validate.result' => (
        {'type', 'protocolVersion', 'requestId', 'ready', 'issues', 'models'},
        {'models'},
      ),
    'progress' => (
        {
          'type',
          'protocolVersion',
          'requestId',
          'assignmentId',
          'message',
          'percentage'
        },
        {'percentage'},
      ),
    'result' => (
        {
          'type',
          'protocolVersion',
          'requestId',
          'assignmentId',
          'output',
          'artifacts'
        },
        {'artifacts'},
      ),
    'error' => (
        {
          'type',
          'protocolVersion',
          'requestId',
          'assignmentId',
          'code',
          'message',
          'retryable'
        },
        {'assignmentId'},
      ),
    'health.result' => (
        {'type', 'protocolVersion', 'requestId', 'healthy', 'message'},
        {'message'},
      ),
    'version.result' => (
        {'type', 'protocolVersion', 'requestId', 'adapterVersion'},
        <String>{},
      ),
    _ => throw FormatException('unexpected adapter response type: $type'),
  };
  if (value.keys.any((key) => !allowed.contains(key)) ||
      allowed.difference(optional).any((key) => !value.containsKey(key))) {
    throw const FormatException('adapter frame fields do not match its type');
  }
  if (!_nonEmpty(value['requestId']) ||
      (value['adapterVersion'] != null &&
          !_boundedString(value['adapterVersion'], 128)) ||
      (value['message'] != null && !_boundedString(value['message'], 16384)) ||
      (value['code'] != null && !_boundedString(value['code'], 128))) {
    throw const FormatException('adapter response string fields are invalid');
  }
  if (type == 'initialize.result' &&
      (!_nonEmpty(value['adapterVersion']) ||
          !_stringList(value['capabilities'], 128, 128))) {
    throw const FormatException('adapter initialization result is invalid');
  }
  if (type == 'validate.result') {
    final issues = value['issues'];
    final models = value['models'] ?? const <String>[];
    if (value['ready'] is! bool ||
        issues is! List ||
        issues.length > 128 ||
        issues.any((issue) =>
            issue is! Map ||
            issue.keys.toSet().difference({'code', 'message'}).isNotEmpty ||
            issue.keys.toSet().length != 2 ||
            !_boundedString(issue['code'], 128) ||
            !_boundedString(issue['message'], 16384)) ||
        models is! List ||
        models.length > 500 ||
        models
            .any((model) => !_boundedString(model, 256) || !_nonEmpty(model))) {
      throw const FormatException('adapter validation result is invalid');
    }
    value['models'] = models;
  }
  if (type == 'progress' &&
      (!_nonEmpty(value['assignmentId']) ||
          !_boundedString(value['message'], 16384) ||
          (value['percentage'] != null &&
              (value['percentage'] is! num ||
                  (value['percentage'] as num) < 0 ||
                  (value['percentage'] as num) > 100)))) {
    throw const FormatException('adapter progress frame is invalid');
  }
  if (type == 'result') {
    final artifacts = value['artifacts'] ?? const [];
    if (!_nonEmpty(value['assignmentId']) ||
        !_boundedString(value['output'], 512000) ||
        artifacts is! List ||
        artifacts.length > 128 ||
        artifacts.any((artifact) =>
            artifact is! Map ||
            artifact.keys
                .toSet()
                .difference({'name', 'mediaType', 'content'}).isNotEmpty ||
            artifact.keys.toSet().length != 3 ||
            !_boundedString(artifact['name'], 256) ||
            !_boundedString(artifact['mediaType'], 128) ||
            !_boundedString(artifact['content'], 256000))) {
      throw const FormatException('adapter result frame is invalid');
    }
    value['artifacts'] = artifacts;
  }
  if (type == 'error' &&
      (!_nonEmpty(value['code']) ||
          !_boundedString(value['message'], 16384) ||
          value['retryable'] is! bool ||
          (value['assignmentId'] != null &&
              !_nonEmpty(value['assignmentId'])))) {
    throw const FormatException('adapter error frame is invalid');
  }
  if (type == 'health.result' &&
      (value['healthy'] is! bool ||
          (value['message'] != null &&
              !_boundedString(value['message'], 2048)))) {
    throw const FormatException('adapter health result is invalid');
  }
  if (type == 'version.result' && !_nonEmpty(value['adapterVersion'])) {
    throw const FormatException('adapter version result is invalid');
  }
  return value;
}

String serializeV7AdapterFrame(Map<String, Object?> value) {
  final type = value['type'];
  if (value['protocolVersion'] != v7AdapterProtocolVersion ||
      !_nonEmpty(value['requestId']) ||
      type is! String) {
    throw const FormatException('adapter request envelope is invalid');
  }
  final allowed = switch (type) {
    'initialize.request' => {
        'type',
        'protocolVersion',
        'requestId',
        'workerTypeId',
        'adapterVersion'
      },
    'validate.request' => {'type', 'protocolVersion', 'requestId', 'config'},
    'execute.request' => {
        'type',
        'protocolVersion',
        'requestId',
        'assignmentId',
        'prompt',
        'model'
      },
    'health.request' || 'version.request' => {
        'type',
        'protocolVersion',
        'requestId'
      },
    _ => throw FormatException('unexpected adapter request type: $type'),
  };
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('adapter request has unknown fields');
  }
  if (type == 'initialize.request' &&
      (!_nonEmpty(value['workerTypeId']) ||
          !_nonEmpty(value['adapterVersion']))) {
    throw const FormatException('adapter initialization request is invalid');
  }
  if (type == 'validate.request') {
    final config = value['config'];
    if (config is! Map ||
        config.length > 128 ||
        config.values.any((item) =>
            item != null && item is! String && item is! num && item is! bool) ||
        config.values.whereType<String>().any((item) => item.length > 4096)) {
      throw const FormatException('adapter validation config is invalid');
    }
  }
  if (type == 'execute.request' &&
      (!_nonEmpty(value['assignmentId']) ||
          !_boundedString(value['prompt'], 512000) ||
          (value['model'] != null && !_boundedString(value['model'], 256)))) {
    throw const FormatException('adapter execution request is invalid');
  }
  final frame = jsonEncode(value);
  if (utf8.encode(frame).length > v7AdapterMaxFrameBytes) {
    throw const FormatException('adapter frame exceeds the 1 MB limit');
  }
  return frame;
}

bool _nonEmpty(Object? value) => value is String && value.trim().isNotEmpty;
bool _boundedString(Object? value, int max) =>
    value is String && value.length <= max;
bool _stringList(Object? value, int maxItems, int maxLength) =>
    value is List &&
    value.length <= maxItems &&
    value.every((item) =>
        item is String && item.trim().isNotEmpty && item.length <= maxLength);
