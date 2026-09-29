import 'configured_worker_registry.dart';
import 'first_party_worker_adapter_descriptor.dart';

/// Persists local Worker configuration without accepting provider credentials.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({
    required this.registry,
    this.requireStepUp,
  });

  final LocalConfiguredWorkerRegistry registry;
  final Future<bool> Function(String reason)? requireStepUp;

  bool _isSupported(FirstPartyWorkerAdapterDescriptor type) =>
      FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId(
        type.productWorkerTypeId,
      ) ==
      type;

  Future<LocalConfiguredWorker> create({
    required FirstPartyWorkerAdapterDescriptor type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
    String? executablePath,
    String? cliVersion,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    final permissionsReady =
        type.requiredLocalPermissions.every(permissions.contains);
    final isReady = authenticationReady &&
        adapterReady &&
        prerequisiteReady &&
        permissionsReady;
    return registry.create(
      name: type.productName,
      workerTypeId: type.productWorkerTypeId,
      authStrategy: type.authStrategy,
      defaultModel: null,
      adapterConfig: const {},
      allowedModels: const [],
      localPermissions: permissions,
      localConcurrencyLimit: type.defaultLocalConcurrency,
      executablePath: executablePath,
      cliVersion: cliVersion,
      status:
          isReady ? LocalWorkerStatus.ready : LocalWorkerStatus.needsAttention,
      credentialStatus: authenticationReady
          ? LocalWorkerCredentialStatus.ready
          : LocalWorkerCredentialStatus.needsAuthentication,
    );
  }

  Future<LocalConfiguredWorker> update({
    required LocalConfiguredWorker current,
    required FirstPartyWorkerAdapterDescriptor type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
    String? executablePath,
    String? cliVersion,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    if (current.workerTypeId != type.productWorkerTypeId) {
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
    final permissionsReady =
        type.requiredLocalPermissions.every(permissions.contains);
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
        name: type.productName,
        clearModelConfiguration: true,
        executablePath: executablePath,
        cliVersion: cliVersion,
        clearExecutable: executablePath == null || cliVersion == null,
        localPermissions: permissions,
        credentialStatus: authReady
            ? LocalWorkerCredentialStatus.ready
            : LocalWorkerCredentialStatus.needsAuthentication,
        status: status,
      ),
    );
  }
}
