import 'dart:async';
import 'dart:io';

const conclaveProductionCloudUrl = 'https://app.conclaveax.com';
const conclaveWorkspaceAppVersion =
    String.fromEnvironment('CONCLAVE_WORKSPACE_VERSION', defaultValue: '1.0.3');

String normalizeWorkspaceCloudOrigin(String cloudUrl) {
  final parsed = Uri.tryParse(cloudUrl.trim());
  if (parsed == null ||
      !const {'https', 'http'}.contains(parsed.scheme) ||
      parsed.host.isEmpty) {
    throw ArgumentError('Cloud URL must be an HTTP(S) origin.');
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
  ).toString();
}

Uri workspaceCloudApiUri(String cloudUrl, String apiPath) {
  if (!apiPath.startsWith('/api/')) {
    throw ArgumentError.value(apiPath, 'apiPath', 'Must start with /api/.');
  }
  return Uri.parse(normalizeWorkspaceCloudOrigin(cloudUrl))
      .replace(path: apiPath);
}

class WorkspaceEnrollmentResult {
  const WorkspaceEnrollmentResult({
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.workspaceName,
    required this.ownerUserId,
    required this.authToken,
  });

  final String workspaceRuntimeId;
  final String workspaceId;
  final String workspaceName;
  final String? ownerUserId;
  final String authToken;

  factory WorkspaceEnrollmentResult.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Workspace enrollment response is missing $key');
      }
      return value.trim();
    }

    return WorkspaceEnrollmentResult(
      workspaceRuntimeId: requiredString('workspaceRuntimeId'),
      workspaceId: requiredString('workspaceId'),
      workspaceName: requiredString('workspaceName'),
      ownerUserId: json['ownerUserId'] is String
          ? (json['ownerUserId'] as String).trim()
          : null,
      authToken: requiredString(json.containsKey('runtimeCredential')
          ? 'runtimeCredential'
          : 'authToken'),
    );
  }
}

/// Safe machine facts submitted during Workspace claim/enrollment.
///
/// Under the Conclave safety contract, this payload contains only safe,
/// non-sensitive platform metadata and runtime capabilities. It MUST NEVER
/// contain API keys, credentials, cookies, private paths, or filesystem contents.
class SafeMachineFacts {
  const SafeMachineFacts({
    required this.installationId,
    required this.name,
    required this.hostname,
    required this.platform,
    required this.architecture,
    required this.appVersion,
    required this.runtimeCapabilities,
  });

  final String installationId;
  final String name;
  final String hostname;
  final String platform;
  final String architecture;
  final String appVersion;
  final Map<String, Object?> runtimeCapabilities;

  Map<String, Object?> toJson(
      {required String token, bool allowRecovery = false}) {
    final payload = <String, Object?>{
      'token': token.trim(),
      'hostname': hostname.trim(),
      'installationId': installationId.trim(),
      if (name.trim().isNotEmpty) 'name': name.trim(),
      'platform': platform.trim(),
      'architecture': architecture.trim(),
      'appVersion': appVersion.trim(),
      'runtimeCapabilities': runtimeCapabilities,
      if (allowRecovery) 'allowRecovery': true,
    };
    validateSafePayload(payload);
    return payload;
  }

  static SafeMachineFacts collect({
    required String installationId,
    required String name,
    String? hostname,
    String? platform,
    String? architecture,
    String? appVersion,
    Map<String, Object?>? capabilities,
  }) {
    final os = platform ?? Platform.operatingSystem;
    final arch = architecture ?? detectArchitecture();
    final ver = appVersion ?? conclaveWorkspaceAppVersion;
    final workspace = hostname ?? Platform.localHostname;
    final caps = capabilities ??
        defaultRuntimeCapabilities(os: os, arch: arch, appVersion: ver);

    return SafeMachineFacts(
      installationId: installationId,
      name: name,
      hostname: workspace,
      platform: os,
      architecture: arch,
      appVersion: ver,
      runtimeCapabilities: caps,
    );
  }

  static Map<String, Object?> defaultRuntimeCapabilities({
    required String os,
    required String arch,
    required String appVersion,
  }) {
    return {
      'os': os,
      'arch': arch,
      'appVersion': appVersion,
      'supportedRuntimes': const <String>['dart'],
      'maxConcurrentWorkers': 1,
    };
  }

  static String detectArchitecture() {
    final version = Platform.version.toLowerCase();
    final envHint =
        '${Platform.environment['PROCESSOR_ARCHITECTURE'] ?? ''} ${Platform.environment['HOSTTYPE'] ?? ''}'
            .toLowerCase();
    if (version.contains('arm64') ||
        version.contains('aarch64') ||
        envHint.contains('arm64') ||
        envHint.contains('aarch64')) {
      return 'arm64';
    }
    return 'x64';
  }

  /// Verifies that no sensitive keys or paths are present in machine facts.
  static void validateSafePayload(Map<String, Object?> payload) {
    const forbidden = {
      'apikey',
      'api_key',
      'secret',
      'secrets',
      'password',
      'cookie',
      'cookies',
      'credential',
      'credentials',
      'authtoken',
      'auth_token',
      'homedirectory',
      'home_directory',
      'workroot',
      'work_root',
      'filesystem',
      'inventory',
    };

    void scan(Object? value, [String path = '']) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase().replaceAll('_', '');
          if (forbidden.contains(key) && entry.key != 'token') {
            throw ArgumentError(
                'Prohibited secret or sensitive metadata in machine facts: ${entry.key}');
          }
          scan(entry.value, '$path.${entry.key}');
        }
      } else if (value is List) {
        for (final item in value) {
          scan(item, path);
        }
      }
    }

    scan(payload);
  }
}

enum WorkspacePairingErrorKind {
  invalidCode,
  expiredCode,
  alreadyUsed,
  cloudUnavailable,
  installationAlreadyPaired,
  workspaceOrAccountRevoked,
  versionUnsupported,
  serverValidationFailure,
  unknown,
}

class WorkspacePairingException implements Exception {
  const WorkspacePairingException({
    required this.kind,
    required this.message,
    required this.action,
    this.statusCode,
    this.serverError,
    this.serverCode,
  });

  final WorkspacePairingErrorKind kind;
  final String message;
  final String action;
  final int? statusCode;
  final String? serverError;
  final String? serverCode;

  String get displayTitle => message;
  String get displayAction => action;

  @override
  String toString() => '$message $action'.trim();

  factory WorkspacePairingException.fromError({
    int? statusCode,
    String? serverError,
    String? serverCode,
    Object? underlyingError,
  }) {
    final lowerError = (serverError ?? '').toLowerCase();
    final lowerCode = (serverCode ?? '').toLowerCase();

    // 1. Network / connectivity / server errors
    if (underlyingError is SocketException ||
        underlyingError is HttpException ||
        underlyingError is HandshakeException ||
        underlyingError is TlsException ||
        underlyingError is TimeoutException ||
        (statusCode != null && statusCode >= 500)) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.cloudUnavailable,
        message: 'Unable to connect to Conclave Cloud.',
        action: 'Check your internet connection or verify the Cloud URL.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    // 2. Explicit serverCode matching
    if (lowerCode == 'pairing_code_expired') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.expiredCode,
        message: 'This pairing code has expired.',
        action: 'Generate a new code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'pairing_already_claimed' ||
        lowerCode == 'pairing_already_used') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.alreadyUsed,
        message: 'This pairing code has already been used.',
        action:
            'Generate a fresh pairing code in Conclave AX to connect this Workspace.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'installation_already_paired') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.installationAlreadyPaired,
        message: 'This installation is already connected to a Workspace.',
        action:
            'Disconnect the current Workspace before connecting to another account.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'installation_recovery_required') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.installationAlreadyPaired,
        message: 'This installation needs explicit pairing recovery.',
        action:
            'Use Disconnect in Conclave Workspace on the previously paired installation, then retry with a fresh code.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'account_revoked' || lowerCode == 'workspace_revoked') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.workspaceOrAccountRevoked,
        message: 'The associated account or Workspace is inactive or revoked.',
        action: 'Sign in to Conclave AX to verify your account status.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'version_unsupported') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.versionUnsupported,
        message: 'This version of Conclave Workspace is no longer supported.',
        action: 'Please update Conclave Workspace to the latest version.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerCode == 'invalid_pairing_code' ||
        lowerCode == 'pairing_code_cancelled' ||
        lowerCode == 'token_required') {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.invalidCode,
        message: 'The pairing code is invalid.',
        action: 'Check the code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    // 3. HTTP status code matching
    if (statusCode == 410) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.expiredCode,
        message: 'This pairing code has expired.',
        action: 'Generate a new code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (statusCode == 409) {
      if (lowerError.contains('already paired') ||
          lowerError.contains('already connected')) {
        return WorkspacePairingException(
          kind: WorkspacePairingErrorKind.installationAlreadyPaired,
          message: 'This installation is already connected to a Workspace.',
          action:
              'Disconnect the current Workspace before connecting to another account.',
          statusCode: statusCode,
          serverError: serverError,
          serverCode: serverCode,
        );
      }
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.alreadyUsed,
        message: 'This pairing code has already been used.',
        action:
            'Generate a fresh pairing code in Conclave AX to connect this Workspace.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (statusCode == 403) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.workspaceOrAccountRevoked,
        message: 'The associated account or Workspace is inactive or revoked.',
        action: 'Sign in to Conclave AX to verify your account status.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (statusCode == 401 || statusCode == 404) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.invalidCode,
        message: 'The pairing code is invalid.',
        action: 'Check the code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (statusCode == 400 || statusCode == 422) {
      if (lowerError.contains('version') &&
          lowerError.contains('unsupported')) {
        return WorkspacePairingException(
          kind: WorkspacePairingErrorKind.versionUnsupported,
          message: 'This version of Conclave Workspace is no longer supported.',
          action: 'Please update Conclave Workspace to the latest version.',
          statusCode: statusCode,
          serverError: serverError,
          serverCode: serverCode,
        );
      }
      if (lowerError.contains('token is required') ||
          lowerError.contains('pairing code is required')) {
        return WorkspacePairingException(
          kind: WorkspacePairingErrorKind.invalidCode,
          message: 'The pairing code is invalid.',
          action: 'Check the code in Conclave AX and try again.',
          statusCode: statusCode,
          serverError: serverError,
          serverCode: serverCode,
        );
      }
      final detail = serverError?.isNotEmpty == true
          ? serverError!
          : 'Check the Workspace name and machine settings.';
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.serverValidationFailure,
        message: 'Registration details were rejected by the server.',
        action: detail,
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    // 4. Text fallbacks
    if (lowerError.contains('expired')) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.expiredCode,
        message: 'This pairing code has expired.',
        action: 'Generate a new code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerError.contains('already claimed') ||
        lowerError.contains('already used')) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.alreadyUsed,
        message: 'This pairing code has already been used.',
        action:
            'Generate a fresh pairing code in Conclave AX to connect this Workspace.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerError.contains('already connected') ||
        lowerError.contains('already paired')) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.installationAlreadyPaired,
        message: 'This installation is already connected to a Workspace.',
        action:
            'Disconnect the current Workspace before connecting to another account.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerError.contains('no longer active') ||
        lowerError.contains('revoked')) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.workspaceOrAccountRevoked,
        message: 'The associated account or Workspace is inactive or revoked.',
        action: 'Sign in to Conclave AX to verify your account status.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    if (lowerError.contains('invalid') ||
        lowerError.contains('cancelled') ||
        lowerError.contains('not found')) {
      return WorkspacePairingException(
        kind: WorkspacePairingErrorKind.invalidCode,
        message: 'The pairing code is invalid.',
        action: 'Check the code in Conclave AX and try again.',
        statusCode: statusCode,
        serverError: serverError,
        serverCode: serverCode,
      );
    }

    // Fallback unknown
    return WorkspacePairingException(
      kind: WorkspacePairingErrorKind.unknown,
      message: serverError?.isNotEmpty == true
          ? serverError!
          : 'Pairing could not be completed.',
      action: 'Please try again or export diagnostics if the problem persists.',
      statusCode: statusCode,
      serverError: serverError,
      serverCode: serverCode,
    );
  }
}
