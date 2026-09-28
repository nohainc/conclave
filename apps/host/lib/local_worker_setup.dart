import 'adapter_prerequisite.dart';
import 'configured_worker_registry.dart';

class LocalWorkerTypeOption {
  const LocalWorkerTypeOption({
    required this.id,
    required this.adapterId,
    required this.name,
    required this.description,
    required this.authStrategy,
    required this.prerequisite,
    this.executablePrerequisite,
    required this.permissions,
  });

  final String id;
  final String adapterId;
  final String name;
  final String description;
  final String authStrategy;
  final String prerequisite;
  final AdapterExecutablePrerequisite? executablePrerequisite;
  final List<String> permissions;

  static const supported = <LocalWorkerTypeOption>[
    LocalWorkerTypeOption(
      id: 'chatgpt',
      adapterId: 'codex',
      name: 'ChatGPT',
      description: 'Use ChatGPT through the Codex CLI on this computer.',
      authStrategy: 'browser_auth',
      prerequisite: 'Codex CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
        executable: 'codex',
      ),
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
    LocalWorkerTypeOption(
      id: 'gemini',
      adapterId: 'antigravity',
      name: 'Gemini',
      description: 'Use Gemini through the Antigravity CLI on this computer.',
      authStrategy: 'browser_auth',
      prerequisite: 'Antigravity CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
        executable: 'agy',
      ),
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
  ];
}

/// Persists local Worker configuration without accepting provider credentials.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({
    required this.registry,
    this.requireStepUp,
  });

  final LocalConfiguredWorkerRegistry registry;
  final Future<bool> Function(String reason)? requireStepUp;

  bool _isSupported(LocalWorkerTypeOption type) =>
      LocalWorkerTypeOption.supported.any((option) => option.id == type.id);

  Future<LocalConfiguredWorker> create({
    required LocalWorkerTypeOption type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    final permissionsReady = type.permissions.every(permissions.contains);
    final isReady = authenticationReady &&
        adapterReady &&
        prerequisiteReady &&
        permissionsReady;
    return registry.create(
      name: type.name,
      workerTypeId: type.id,
      authStrategy: type.authStrategy,
      defaultModel: null,
      adapterConfig: const {},
      allowedModels: const [],
      localPermissions: permissions,
      status:
          isReady ? LocalWorkerStatus.ready : LocalWorkerStatus.needsAttention,
      credentialStatus: authenticationReady
          ? LocalWorkerCredentialStatus.ready
          : LocalWorkerCredentialStatus.needsAuthentication,
    );
  }

  Future<LocalConfiguredWorker> update({
    required LocalConfiguredWorker current,
    required LocalWorkerTypeOption type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    if (current.workerTypeId != type.id) {
      throw ArgumentError('Worker Type cannot be changed while editing.');
    }
    final permissionsChanged =
        permissions.length != current.localPermissions.length ||
            !permissions.toSet().containsAll(current.localPermissions);
    if (permissionsChanged) {
      final gate = requireStepUp;
      if (gate == null ||
          !await gate('Change local Worker execution permissions')) {
        throw StateError(
            'Local authentication is required to save these changes.');
      }
    }
    final authReady = authenticationReady ||
        current.credentialStatus == LocalWorkerCredentialStatus.ready;
    final permissionsReady = type.permissions.every(permissions.contains);
    final isReady =
        authReady && adapterReady && prerequisiteReady && permissionsReady;
    final status = current.status == LocalWorkerStatus.disabled
        ? LocalWorkerStatus.disabled
        : isReady
            ? LocalWorkerStatus.ready
            : LocalWorkerStatus.needsAttention;
    return registry.update(
      current.id,
      (record) => record.copyWith(
        name: type.name,
        clearModelConfiguration: true,
        localPermissions: permissions,
        credentialStatus: authReady
            ? LocalWorkerCredentialStatus.ready
            : LocalWorkerCredentialStatus.needsAuthentication,
        status: status,
      ),
    );
  }
}
