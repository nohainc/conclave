import 'dart:convert';

import 'initialize_frames.dart';
import 'limits.dart';
import 'protocol_version.dart';
import 'worker_issue_codes.dart';

/// Internal WorkerProgress control marker emitted once the Engine has started
/// the provider process. Host supervisors consume it for deterministic tests
/// and do not forward it as user-facing progress.
const workerProviderExecutionStartedMessage =
    'conclave.engine.provider_execution_started.v1';

enum WorkerProbeMode { passive, live }

enum WorkerSessionPolicy { stateless, durableSession }

enum ProbeCheckStatus { passed, failed, warning }

final class ProbeRequest extends WorkerFrame {
  ProbeRequest({
    required super.requestId,
    required this.mode,
    this.timeoutMs = WorkerProtocolLimits.maxProbeTimeoutMs,
    this.protocolVersion = localWorkerProtocolVersion,
  }) {
    _validateProtocol(protocolVersion);
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (timeoutMs < 100 || timeoutMs > WorkerProtocolLimits.maxProbeTimeoutMs) {
      throw const FormatException('probe timeout is outside the allowed range');
    }
  }

  final String protocolVersion;

  /// `passive` guarantees no provider model request; `live` may consume quota.
  final WorkerProbeMode mode;
  final int timeoutMs;

  @override
  String get type => 'probe.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'mode': mode.name,
        'timeoutMs': timeoutMs,
      };

  factory ProbeRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'type', 'protocolVersion', 'requestId', 'mode', 'timeoutMs'},
    );
    _expectType(json, 'probe.request');
    final mode = _requiredString(json, 'mode');
    return ProbeRequest(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      protocolVersion: _requiredString(json, 'protocolVersion'),
      mode: WorkerProbeMode.values.firstWhere(
        (candidate) => candidate.name == mode,
        orElse: () =>
            throw const FormatException('probe mode must be passive or live'),
      ),
      timeoutMs: _probeTimeout(json),
    );
  }
}

int _probeTimeout(Map<String, Object?> json) {
  final value = json['timeoutMs'] ?? WorkerProtocolLimits.maxProbeTimeoutMs;
  if (value is! int ||
      value < 100 ||
      value > WorkerProtocolLimits.maxProbeTimeoutMs) {
    throw const FormatException('probe timeout is outside the allowed range');
  }
  return value;
}

final class ProviderToolInfo {
  ProviderToolInfo({required String name, String? version, String? path})
      : name = _boundedText(
          name,
          'tool name',
          WorkerProtocolLimits.maxProviderToolNameLength,
        ),
        version = version == null
            ? null
            : _boundedText(
                version,
                'tool version',
                WorkerProtocolLimits.maxProviderToolVersionLength,
              ),
        path = path;

  final String name;
  final String? version;

  /// Local diagnostics only. Never include this field in Cloud inventory.
  final String? path;

  Map<String, Object?> toJson() => {
        'name': name,
        if (version != null) 'version': version,
      };

  factory ProviderToolInfo.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'name', 'version'});
    return ProviderToolInfo(
      name: _requiredString(json, 'name'),
      version: _optionalString(json, 'version'),
      path: _optionalString(json, 'path'),
    );
  }
}

final class ProbeCheck {
  ProbeCheck({
    required String code,
    required this.status,
    required String message,
  })  : code = _boundedText(
          code,
          'check code',
          WorkerProtocolLimits.maxCheckCodeLength,
        ),
        message = _safeBoundedText(
          message,
          'check message',
          WorkerProtocolLimits.maxCheckMessageLength,
        ) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(this.code)) {
      throw const FormatException(
        'check code must be a stable lowercase issue identifier',
      );
    }
  }

  final String code;
  final ProbeCheckStatus status;
  final String message;

  Map<String, Object?> toJson() => {
        'code': code,
        'status': status.name,
        'message': message,
      };

  factory ProbeCheck.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'code', 'status', 'message'});
    final status = _requiredString(json, 'status');
    return ProbeCheck(
      code: _requiredString(json, 'code'),
      status: ProbeCheckStatus.values.firstWhere(
        (candidate) => candidate.name == status,
        orElse: () => throw const FormatException('invalid probe check status'),
      ),
      message: _requiredString(json, 'message'),
    );
  }
}

final class ProbeResult extends WorkerFrame {
  ProbeResult({
    required super.requestId,
    required this.mode,
    required this.ready,
    required Iterable<ProbeCheck> checks,
    ProviderToolInfo? tool,
    String? providerToolName,
    String? providerToolVersion,
    String? issueCode,
    String? diagnostics,
  })  : providerToolName = (providerToolName ?? tool?.name) == null
            ? null
            : _safeToolName(providerToolName ?? tool!.name),
        providerToolVersion = (providerToolVersion ?? tool?.version) == null
            ? null
            : _safeToolVersion(providerToolVersion ?? tool!.version!),
        checks = List.unmodifiable(checks),
        issueCode = issueCode == null
            ? null
            : _boundedText(
                issueCode,
                'issueCode',
                WorkerProtocolLimits.maxCheckCodeLength,
              ),
        diagnostics = diagnostics == null
            ? null
            : _safeBoundedText(
                diagnostics,
                'diagnostics',
                WorkerProtocolLimits.maxDiagnosticLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (this.checks.length > WorkerProtocolLimits.maxProbeChecks) {
      throw const FormatException('too many probe checks');
    }
    if (!ready && this.issueCode == null) {
      throw const FormatException(
        'a not-ready probe result requires an issueCode',
      );
    }
    if (this.providerToolName == null && this.providerToolVersion != null) {
      throw const FormatException(
        'providerToolVersion requires providerToolName',
      );
    }
    if (this.issueCode != null && !WorkerIssueCode.isKnown(this.issueCode!)) {
      throw const FormatException('issueCode is not a supported stable code');
    }
  }

  final WorkerProbeMode mode;
  final bool ready;
  final String? providerToolName;
  final String? providerToolVersion;
  @Deprecated('Use providerToolName and providerToolVersion')
  ProviderToolInfo? get tool => providerToolName == null
      ? null
      : ProviderToolInfo(name: providerToolName!, version: providerToolVersion);
  final List<ProbeCheck> checks;
  final String? issueCode;
  final String? diagnostics;

  @override
  String get type => 'probe.result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'mode': mode.name,
        'ready': ready,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        'checks': checks.map((check) => check.toJson()).toList(growable: false),
        'issueCode': issueCode,
        'diagnostics': diagnostics,
      };

  factory ProbeResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'mode',
      'ready',
      'providerToolName',
      'providerToolVersion',
      'checks',
      'issueCode',
      'diagnostics',
    });
    _expectType(json, 'probe.result');
    final rawMode = _requiredString(json, 'mode');
    final rawReady = json['ready'];
    final rawToolName = json['providerToolName'];
    final rawToolVersion = json['providerToolVersion'];
    final rawChecks = json['checks'];
    if (rawReady is! bool)
      throw const FormatException('ready must be a boolean');
    if (rawToolName != null && rawToolName is! String)
      throw const FormatException('providerToolName must be a string or null');
    if (rawToolVersion != null && rawToolVersion is! String)
      throw const FormatException(
          'providerToolVersion must be a string or null');
    if (rawToolName == null && rawToolVersion != null)
      throw const FormatException(
          'providerToolVersion requires providerToolName');
    if (rawChecks is! List ||
        rawChecks.length > WorkerProtocolLimits.maxProbeChecks) {
      throw const FormatException('checks must be a bounded array');
    }
    return ProbeResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      mode: _parseProbeMode(rawMode),
      ready: rawReady,
      providerToolName: rawToolName as String?,
      providerToolVersion: rawToolVersion as String?,
      checks: rawChecks.map((check) {
        if (check is! Map)
          throw const FormatException('each check must be an object');
        return ProbeCheck.fromJson(Map<String, Object?>.from(check));
      }).toList(growable: false),
      issueCode: _optionalString(json, 'issueCode'),
      diagnostics: _optionalString(json, 'diagnostics'),
    );
  }
}

final class ExecuteRequest extends WorkerFrame {
  ExecuteRequest({
    required super.requestId,
    required this.assignmentId,
    required this.prompt,
    required this.timeoutMs,
    required this.sessionPolicy,
    this.executionPolicy = WorkerExecutionPolicy.restricted,
    this.model,
    this.reasoningEffort,
    this.sessionKey,
    this.protocolVersion = localWorkerProtocolVersion,
  }) {
    _validateProtocol(protocolVersion);
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (prompt.trim().isEmpty) {
      throw const FormatException('prompt must not be empty');
    }
    if (utf8.encode(prompt).length > WorkerProtocolLimits.maxPromptBytes) {
      throw const FormatException('prompt exceeds the byte limit');
    }
    if (timeoutMs < 1 || timeoutMs > WorkerProtocolLimits.maxTimeoutMs) {
      throw const FormatException('timeoutMs is outside the allowed range');
    }
    if (model != null) {
      _validateToken(model!, 'model', WorkerProtocolLimits.maxModelLength);
    }
    if (reasoningEffort != null) {
      _validateToken(
        reasoningEffort!,
        'reasoningEffort',
        WorkerProtocolLimits.maxModelLength,
      );
    }
    if (sessionPolicy == WorkerSessionPolicy.durableSession) {
      if (sessionKey == null)
        throw const FormatException('durable sessions require sessionKey');
      _validateToken(
        sessionKey!,
        'sessionKey',
        WorkerProtocolLimits.maxSessionKeyLength,
      );
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionKey!)) {
        throw const FormatException(
          'sessionKey must be an opaque safe identifier',
        );
      }
    } else if (sessionKey != null) {
      throw const FormatException(
        'stateless execution must not include sessionKey',
      );
    }
  }

  final String protocolVersion;
  final String assignmentId;
  final String prompt;
  final String? model;
  final String? reasoningEffort;
  final int timeoutMs;
  final WorkerSessionPolicy sessionPolicy;
  final WorkerExecutionPolicy executionPolicy;
  final String? sessionKey;

  @override
  String get type => 'execute.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'prompt': prompt,
        'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        'timeoutMs': timeoutMs,
        'sessionPolicy': sessionPolicy == WorkerSessionPolicy.durableSession
            ? 'durable_session'
            : 'stateless',
        'executionPolicy': executionPolicy.wireValue,
        if (sessionKey != null) 'sessionKey': sessionKey,
      };

  factory ExecuteRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'assignmentId',
      'prompt',
      'model',
      'reasoningEffort',
      'timeoutMs',
      'sessionPolicy',
      'executionPolicy',
      'sessionKey',
    });
    _expectType(json, 'execute.request');
    final model = json['model'];
    if (model != null && model is! String)
      throw const FormatException('model must be a string or null');
    final reasoningEffort = json['reasoningEffort'];
    if (reasoningEffort != null && reasoningEffort is! String) {
      throw const FormatException('reasoningEffort must be a string or null');
    }
    final timeout = json['timeoutMs'];
    if (timeout is! int)
      throw const FormatException('timeoutMs must be an integer');
    final policy = _requiredString(json, 'sessionPolicy');
    final parsedPolicy = switch (policy) {
      'stateless' => WorkerSessionPolicy.stateless,
      'durable_session' => WorkerSessionPolicy.durableSession,
      _ => throw const FormatException('invalid sessionPolicy'),
    };
    final rawExecutionPolicy = json['executionPolicy'] ?? 'restricted';
    if (rawExecutionPolicy is! String) {
      throw const FormatException('executionPolicy must be a string');
    }
    final parsedExecutionPolicy = WorkerExecutionPolicy.fromWireValue(
      rawExecutionPolicy,
    );
    return ExecuteRequest(
      protocolVersion: _requiredString(json, 'protocolVersion'),
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      prompt: _requiredString(json, 'prompt'),
      model: model as String?,
      reasoningEffort: reasoningEffort as String?,
      timeoutMs: timeout,
      sessionPolicy: parsedPolicy,
      executionPolicy: parsedExecutionPolicy,
      sessionKey: _optionalString(json, 'sessionKey'),
    );
  }
}

/// A bounded Workspace-selected sandbox mode. Full access is intentionally
/// excluded from the Local Worker Protocol so assignments cannot request it.
enum WorkerExecutionPolicy {
  restricted('restricted'),
  providerDefault('provider_default');

  const WorkerExecutionPolicy(this.wireValue);
  final String wireValue;

  static WorkerExecutionPolicy fromWireValue(String value) => switch (value) {
        'restricted' => WorkerExecutionPolicy.restricted,
        'provider_default' => WorkerExecutionPolicy.providerDefault,
        _ => throw const FormatException('invalid executionPolicy'),
      };
}

final class WorkerProgress extends WorkerFrame {
  WorkerProgress({
    required super.requestId,
    required this.assignmentId,
    required this.percentage,
    String? message,
  }) : message = message == null
            ? null
            : _safeBoundedText(
                message,
                'progress message',
                WorkerProtocolLimits.maxProgressMessageLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (!percentage.isFinite || percentage < 0 || percentage > 100) {
      throw const FormatException(
        'progress percentage must be between 0 and 100',
      );
    }
  }

  final String assignmentId;
  final double percentage;
  final String? message;

  @override
  String get type => 'progress';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'percentage': percentage,
        if (message != null) 'message': message,
      };

  factory WorkerProgress.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'percentage',
      'message',
    });
    _expectType(json, 'progress');
    final percentage = json['percentage'];
    if (percentage is! num)
      throw const FormatException('percentage must be numeric');
    return WorkerProgress(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      percentage: percentage.toDouble(),
      message: _optionalString(json, 'message'),
    );
  }
}

final class WorkerResult extends WorkerFrame {
  WorkerResult({
    required super.requestId,
    required this.assignmentId,
    required this.output,
    Iterable<String> artifacts = const [],
  }) : artifacts = List.unmodifiable(artifacts) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (utf8.encode(output).length > WorkerProtocolLimits.maxOutputBytes) {
      throw const FormatException('output exceeds the byte limit');
    }
    if (this.artifacts.length > WorkerProtocolLimits.maxArtifacts) {
      throw const FormatException('too many artifacts');
    }
    for (final artifact in this.artifacts) {
      _validateToken(
        artifact,
        'artifact ID',
        WorkerProtocolLimits.maxArtifactIdLength,
      );
    }
  }

  final String assignmentId;
  final String output;
  final List<String> artifacts;

  @override
  String get type => 'result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'output': output,
        'artifacts': artifacts,
      };

  factory WorkerResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'output',
      'artifacts',
    });
    _expectType(json, 'result');
    final rawArtifacts = json['artifacts'];
    if (rawArtifacts is! List ||
        rawArtifacts.length > WorkerProtocolLimits.maxArtifacts) {
      throw const FormatException('artifacts must be a bounded array');
    }
    if (rawArtifacts.any((item) => item is! String)) {
      throw const FormatException('artifact IDs must be strings');
    }
    return WorkerResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      output: _requiredStringAllowEmpty(json, 'output'),
      artifacts: rawArtifacts.cast<String>(),
    );
  }
}

final class WorkerErrorFrame extends WorkerFrame {
  WorkerErrorFrame({
    required super.requestId,
    required String code,
    required String message,
    this.assignmentId,
    this.retryable = false,
    String? diagnostics,
  })  : code = _boundedText(
          code,
          'error code',
          WorkerProtocolLimits.maxCheckCodeLength,
        ),
        message = _safeBoundedText(
          message,
          'error message',
          WorkerProtocolLimits.maxErrorMessageLength,
        ),
        diagnostics = diagnostics == null
            ? null
            : _safeBoundedText(
                diagnostics,
                'diagnostics',
                WorkerProtocolLimits.maxDiagnosticLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (assignmentId != null) {
      _validateToken(
        assignmentId!,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      );
    }
    if (!WorkerIssueCode.isKnown(this.code)) {
      throw const FormatException('error code is not a supported stable code');
    }
  }

  final String? assignmentId;
  final String code;
  final String message;
  final bool retryable;
  final String? diagnostics;

  @override
  String get type => 'error';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        if (assignmentId != null) 'assignmentId': assignmentId,
        'code': code,
        'message': message,
        'retryable': retryable,
        if (diagnostics != null) 'diagnostics': diagnostics,
      };

  factory WorkerErrorFrame.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'code',
      'message',
      'retryable',
      'diagnostics',
    });
    _expectType(json, 'error');
    final retryable = json['retryable'];
    if (retryable is! bool)
      throw const FormatException('retryable must be a boolean');
    return WorkerErrorFrame(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _optionalString(json, 'assignmentId'),
      code: _requiredString(json, 'code'),
      message: _requiredString(json, 'message'),
      retryable: retryable,
      diagnostics: _optionalString(json, 'diagnostics'),
    );
  }
}

void validateInitializeAdmission(
  InitializeResult result, {
  required String expectedWorkerTypeId,
  required String expectedEngineVersion,
  required String expectedProfileDefinitionId,
  required String expectedProfileReleaseVersion,
  required int expectedProfileSchemaVersion,
  required Set<String> requiredCapabilities,
  String negotiatedProtocolVersion = localWorkerProtocolVersion,
}) {
  if (result.workerTypeId != expectedWorkerTypeId) {
    throw const FormatException(
      'initialized Worker Type does not match manifest',
    );
  }
  if (result.engineVersion != expectedEngineVersion) {
    throw const FormatException(
      'initialized Engine version does not match admission',
    );
  }
  if (result.profileDefinitionId != expectedProfileDefinitionId ||
      result.profileReleaseVersion != expectedProfileReleaseVersion) {
    throw const FormatException(
        'initialized Tool Profile does not match admission');
  }
  if (result.protocolVersion != negotiatedProtocolVersion) {
    throw const FormatException(
      'initialized protocol does not match negotiation',
    );
  }
  if (result.profileSchemaVersion != expectedProfileSchemaVersion) {
    throw const FormatException(
      'Tool Profile schema does not match admission',
    );
  }
  if (!result.capabilities.toSet().containsAll(requiredCapabilities)) {
    throw const FormatException('Worker is missing required capabilities');
  }
}

WorkerProbeMode _parseProbeMode(String value) =>
    WorkerProbeMode.values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () =>
          throw const FormatException('probe mode must be passive or live'),
    );

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('expected $type frame');
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

String _requiredStringAllowEmpty(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

String _boundedString(Map<String, Object?> json, String key, int maxLength) {
  final value = _requiredString(json, key);
  _validateToken(value, key, maxLength);
  return value;
}

String _boundedText(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$name is empty or exceeds $maxLength characters');
  }
  return value;
}

String _safeToolName(String value) {
  final safe = _boundedText(
    value,
    'providerToolName',
    WorkerProtocolLimits.maxProviderToolNameLength,
  );
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+()\-]*$').hasMatch(safe)) {
    throw const FormatException('providerToolName must be safe display text');
  }
  return safe;
}

String _safeToolVersion(String value) {
  final safe = _boundedText(
    value,
    'providerToolVersion',
    WorkerProtocolLimits.maxProviderToolVersionLength,
  );
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_\-]*$').hasMatch(safe)) {
    throw const FormatException(
        'providerToolVersion must be a safe version token');
  }
  return safe;
}

String _safeBoundedText(String value, String name, int maxLength) {
  final redacted = value
      .replaceAll(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        r'$1[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*["'])([^"']*)(["'])|(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*)([^\s,}&]+)''',
          caseSensitive: false,
        ),
        r'$1[REDACTED]$3$4[REDACTED]',
      );
  return _boundedText(redacted, name, maxLength);
}

void _validateToken(String value, String name, int maxLength) =>
    _boundedText(value, name, maxLength);

void _validateProtocol(String version) {
  if (version != localWorkerProtocolVersion) {
    throw FormatException('unsupported protocol version: $version');
  }
}
