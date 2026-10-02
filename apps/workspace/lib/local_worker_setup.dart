import 'local_worker_registry.dart';
import 'local_worker_permissions.dart';
import 'tool_profile_catalog.dart';

/// Persists local Worker configuration without accepting provider credentials.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({required this.registry});

  final LocalWorkerRegistry registry;

  Future<LocalWorker> createCatalogWorker({
    required LogicalWorkerCatalogEntry entry,
    required List<String> permissions,
  }) {
    if (entry.engineFamily != 'cli') {
      throw ArgumentError('This Worker requires an unsupported Engine family.');
    }
    return registry.create(
      catalogEntry: entry,
      localPermissions: permissions,
      localConcurrencyLimit: defaultLocalWorkerConcurrency,
      status: LocalWorkerStatus.needsAttention,
    );
  }
}
