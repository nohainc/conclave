import 'dart:convert';

import 'package:conclave_protocol/conclave_protocol.dart';

const v7AdapterProtocolVersion = '2.1';
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
    'probe.result' => (
        {
          'type',
          'protocolVersion',
          'requestId',
          'ready',
          'toolVersion',
          'checkKind',
          'issues',
          'models'
        },
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
    _ => throw FormatException('unexpected adapter response type: $type'),
  };
  if (value.keys.any((key) => !allowed.contains(key)) ||
      allowed.difference(optional).any((key) => !value.containsKey(key))) {
    throw const FormatException('adapter frame fields do not match its type');
  }
  if (!_nonEmpty(value['requestId'], max: 128) ||
      (value['adapterVersion'] != null &&
          !_boundedString(value['adapterVersion'], 128)) ||
      (value['message'] != null && !_boundedString(value['message'], 16384)) ||
      (value['code'] != null && !_boundedString(value['code'], 128))) {
    throw const FormatException('adapter response string fields are invalid');
  }
  if (type == 'initialize.result' &&
      (!_nonEmpty(value['adapterVersion'], max: 128) ||
          !_stringList(value['capabilities'], 128, 128))) {
    throw const FormatException('adapter initialization result is invalid');
  }
  if (type == 'probe.result') {
    final issues = value['issues'];
    if (value['ready'] is! bool ||
        value['checkKind'] != 'readiness' ||
        (value['toolVersion'] != null &&
            !_nonEmpty(value['toolVersion'], max: 128)) ||
        issues is! List ||
        issues.length > 128 ||
        issues.any((issue) =>
            issue is! Map ||
            issue.keys.toSet().difference({'code', 'message'}).isNotEmpty ||
            issue.keys.toSet().length != 2 ||
            !_nonEmpty(issue['code'], max: 128) ||
            !_nonEmpty(issue['message'], max: 16384)) ||
        (value['models'] != null && !_stringList(value['models'], 500, 256))) {
      throw const FormatException('adapter probe result is invalid');
    }
  }
  if (type == 'progress' &&
      (!_nonEmpty(value['assignmentId'], max: 128) ||
          !_nonEmpty(value['message'], max: 16384) ||
          (value['percentage'] != null &&
              (value['percentage'] is! num ||
                  (value['percentage'] as num) < 0 ||
                  (value['percentage'] as num) > 100)))) {
    throw const FormatException('adapter progress frame is invalid');
  }
  if (type == 'result') {
    final artifacts = value['artifacts'] ?? const [];
    if (!_nonEmpty(value['assignmentId'], max: 128) ||
        !_boundedString(value['output'], 512000) ||
        artifacts is! List ||
        artifacts.length > 128 ||
        artifacts.any((artifact) =>
            artifact is! Map ||
            artifact.keys
                .toSet()
                .difference({'name', 'mediaType', 'content'}).isNotEmpty ||
            artifact.keys.toSet().length != 3 ||
            !_nonEmpty(artifact['name'], max: 256) ||
            !_nonEmpty(artifact['mediaType'], max: 128) ||
            !_boundedString(artifact['content'], 256000))) {
      throw const FormatException('adapter result frame is invalid');
    }
    value['artifacts'] = artifacts;
  }
  if (type == 'error' &&
      (!_nonEmpty(value['code'], max: 128) ||
          !isExecutionErrorCode(value['code']) ||
          !_nonEmpty(value['message'], max: 16384) ||
          value['retryable'] is! bool ||
          (value['assignmentId'] != null &&
              !_nonEmpty(value['assignmentId'], max: 128)))) {
    throw const FormatException('adapter error frame is invalid');
  }
  return value;
}

String serializeV7AdapterFrame(Map<String, Object?> value) {
  final type = value['type'];
  if (value['protocolVersion'] != v7AdapterProtocolVersion ||
      !_nonEmpty(value['requestId'], max: 128) ||
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
    'probe.request' => {'type', 'protocolVersion', 'requestId', 'config'},
    'execute.request' => {
        'type',
        'protocolVersion',
        'requestId',
        'assignmentId',
        'prompt',
        'model'
      },
    _ => throw FormatException('unexpected adapter request type: $type'),
  };
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('adapter request has unknown fields');
  }
  if (type == 'initialize.request' &&
      (!_nonEmpty(value['workerTypeId'], max: 128) ||
          !_nonEmpty(value['adapterVersion'], max: 128))) {
    throw const FormatException('adapter initialization request is invalid');
  }
  if (type == 'probe.request' && value['config'] != null) {
    final config = value['config'];
    const configKeys = {'endpointUrl', 'organizationId', 'projectId'};
    if (config is! Map ||
        config.keys.any((key) => key is! String || !configKeys.contains(key)) ||
        config.values.any((item) => item is! String) ||
        (config['endpointUrl'] != null &&
            !_safeProbeEndpoint(config['endpointUrl'])) ||
        (config['organizationId'] is String &&
            (config['organizationId'] as String).length > 256) ||
        (config['projectId'] is String &&
            (config['projectId'] as String).length > 256)) {
      throw const FormatException('adapter probe config is invalid');
    }
  }
  if (type == 'execute.request' &&
      (!_nonEmpty(value['assignmentId'], max: 128) ||
          !_boundedString(value['prompt'], 512000) ||
          (value['model'] != null && !_nonEmpty(value['model'], max: 256)))) {
    throw const FormatException('adapter execution request is invalid');
  }
  final frame = jsonEncode(value);
  if (utf8.encode(frame).length > v7AdapterMaxFrameBytes) {
    throw const FormatException('adapter frame exceeds the 1 MB limit');
  }
  return frame;
}

bool _nonEmpty(Object? value, {int max = 4096}) =>
    value is String && value.trim().isNotEmpty && value.length <= max;
bool _safeProbeEndpoint(Object? value) {
  if (value is! String || value.length > 2048) return false;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final local = const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  return uri.scheme == 'https' || (local && uri.scheme == 'http');
}

bool _boundedString(Object? value, int max) =>
    value is String && value.length <= max;
bool _stringList(Object? value, int maxItems, int maxLength) =>
    value is List &&
    value.length <= maxItems &&
    value.every((item) =>
        item is String && item.trim().isNotEmpty && item.length <= maxLength);
