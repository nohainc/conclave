import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

/// Initialize frames for the migration-only native Worker Runtime v2 path.
///
/// Protocol 4.0 initialize frames are deliberately stricter and describe an
/// Engine/Profile pair. These frames keep the old signed-package admission
/// path buildable until its acceptance gate permits removal.
final class LegacyV2InitializeRequest extends WorkerFrame {
  LegacyV2InitializeRequest({
    required super.requestId,
    required this.workerTypeId,
    required this.expectedWorkerVersion,
  }) {
    _validateText(
        requestId, 'requestId', WorkerProtocolLimits.maxRequestIdLength);
    _validateText(
      workerTypeId,
      'workerTypeId',
      WorkerProtocolLimits.maxWorkerTypeIdLength,
    );
    _validateText(
      expectedWorkerVersion,
      'expectedWorkerVersion',
      WorkerProtocolLimits.maxWorkerVersionLength,
    );
  }

  final String workerTypeId;
  final String expectedWorkerVersion;

  @override
  String get type => 'initialize.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': localWorkerProtocolVersion,
        'requestId': requestId,
        'workerTypeId': workerTypeId,
        'expectedWorkerVersion': expectedWorkerVersion,
      };
}

final class LegacyV2InitializeResult extends WorkerFrame {
  LegacyV2InitializeResult({
    required super.requestId,
    required this.workerTypeId,
    required this.workerVersion,
    required this.stateSchemaVersion,
    required Iterable<String> capabilities,
  }) : capabilities = List.unmodifiable(capabilities);

  final String workerTypeId;
  final String workerVersion;
  final int stateSchemaVersion;
  final List<String> capabilities;

  @override
  String get type => 'initialize.result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': localWorkerProtocolVersion,
        'requestId': requestId,
        'workerTypeId': workerTypeId,
        'workerVersion': workerVersion,
        'stateSchemaVersion': stateSchemaVersion,
        'capabilities': capabilities,
      };

  factory LegacyV2InitializeResult.fromJson(Map<String, Object?> json) {
    const fields = {
      'type',
      'protocolVersion',
      'requestId',
      'workerTypeId',
      'workerVersion',
      'stateSchemaVersion',
      'capabilities',
    };
    final rawCapabilities = json['capabilities'];
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        json['type'] != 'initialize.result' ||
        json['protocolVersion'] != localWorkerProtocolVersion ||
        json['requestId'] is! String ||
        json['workerTypeId'] is! String ||
        json['workerVersion'] is! String ||
        json['stateSchemaVersion'] is! int ||
        rawCapabilities is! List ||
        rawCapabilities.length > WorkerProtocolLimits.maxCapabilities ||
        rawCapabilities.any((value) => value is! String)) {
      throw const FormatException('invalid legacy Worker initialize result');
    }
    if (json.keys.toSet().length != fields.length ||
        fields.any((field) => !json.containsKey(field))) {
      throw const FormatException('invalid legacy Worker initialize result');
    }
    final result = LegacyV2InitializeResult(
      requestId: json['requestId'] as String,
      workerTypeId: json['workerTypeId'] as String,
      workerVersion: json['workerVersion'] as String,
      stateSchemaVersion: json['stateSchemaVersion'] as int,
      capabilities: rawCapabilities.cast<String>(),
    );
    _validateText(
      result.requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateText(
      result.workerTypeId,
      'workerTypeId',
      WorkerProtocolLimits.maxWorkerTypeIdLength,
    );
    _validateText(
      result.workerVersion,
      'workerVersion',
      WorkerProtocolLimits.maxWorkerVersionLength,
    );
    if (result.stateSchemaVersion < 1 ||
        result.stateSchemaVersion >
            WorkerProtocolLimits.maxStateSchemaVersion ||
        result.capabilities.toSet().length != result.capabilities.length) {
      throw const FormatException('invalid legacy Worker initialize result');
    }
    for (final capability in result.capabilities) {
      _validateText(
        capability,
        'capability',
        WorkerProtocolLimits.maxCapabilityLength,
      );
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(capability)) {
        throw const FormatException('invalid legacy Worker capability');
      }
    }
    return result;
  }
}

void _validateText(String value, String field, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$field is empty or exceeds $maxLength characters');
  }
}
