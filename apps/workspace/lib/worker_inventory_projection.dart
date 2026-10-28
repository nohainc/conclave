import 'package:syntila_protocol/worker_descriptor.dart';

import 'local_worker_registry.dart';
import 'tool_profile_release_verifier.dart';

/// Spaces a catalog-backed local Worker, failing closed when its Profile or
/// Engine is not eligible for execution.
Map<String, Object?> spaceWorkerInventory({
  required LocalWorker worker,
  required WorkerDescriptor descriptor,
  required ToolProfileCandidate? eligibleProfile,
  required String? engineVersion,
  required String lastSeenAt,
}) {
  final engineAvailable = engineVersion?.trim().isNotEmpty == true;
  final profileMatches = eligibleProfile != null &&
      eligibleProfile.logicalWorkerTypeId == worker.workerTypeId &&
      eligibleProfile.profileDefinitionId == descriptor.profileDefinitionId;
  final runnable = descriptor.workerTypeId == worker.workerTypeId &&
      profileMatches &&
      engineAvailable;
  return {
    'workerId': worker.id,
    'workerTypeId': worker.workerTypeId,
    'activationState':
        worker.activationState == LocalWorkerActivationState.disabled
            ? 'disabled'
            : 'enabled',
    'readinessState': runnable
        ? worker.readinessState.wireValue
        : WorkerReadinessState.runtimeUnavailable.wireValue,
    if (worker.readinessIssueCode != null)
      'readinessIssueCode': worker.readinessIssueCode
    else if (!runnable)
      'readinessIssueCode': !engineAvailable
          ? 'cli_worker_engine_unavailable'
          : 'tool_profile_unavailable',
    'engineVersion': runnable ? engineVersion : null,
    'profileDefinitionId': descriptor.profileDefinitionId,
    'profileReleaseVersion': runnable ? eligibleProfile.releaseVersion : null,
    'providerToolName': descriptor.providerToolName,
    'providerToolVersion': worker.toolVersion,
    if (runnable &&
        worker.modelCatalog?.profileDigest == eligibleProfile.payloadDigest &&
        worker.modelCatalog?.providerToolVersion == worker.toolVersion)
      'modelCatalog': worker.modelCatalog!.toJson(includeNativeIds: false),
    'localConcurrencyLimit': worker.localConcurrencyLimit,
    'revision': worker.revision,
    'createdAt': worker.createdAt,
    'updatedAt': worker.updatedAt,
    'lastSeenAt': lastSeenAt,
  };
}
