import 'configured_worker_registry.dart';
import 'first_party_worker_registry.dart';
import 'local_worker_permissions.dart';

/// Persists local Worker configuration without accepting provider credentials.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({required this.registry});

  final LocalConfiguredWorkerRegistry registry;

  bool _isSupported(FirstPartyWorkerPackage type) =>
      FirstPartyWorkerPackage.forProductWorkerTypeId(
        type.productWorkerTypeId,
      ) ==
      type;

  Future<LocalConfiguredWorker> create({
    required FirstPartyWorkerPackage type,
    required List<String> permissions,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    return registry.create(
      name: type.productName,
      workerTypeId: type.productWorkerTypeId,
      authStrategy: 'browser_auth',
      defaultModel: null,
      adapterConfig: const {},
      allowedModels: const [],
      localPermissions: permissions,
      localConcurrencyLimit: defaultLocalWorkerConcurrency,
      status: LocalWorkerStatus.needsAttention,
      credentialStatus: LocalWorkerCredentialStatus.notRequired,
    );
  }
}
