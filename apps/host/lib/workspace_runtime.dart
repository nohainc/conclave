import 'dart:async';
import 'dart:io';

import 'package:conclave_host/host.dart';
import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/repository_registry.dart';
import 'package:conclave_host/self_update.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';

Set<WorkerPermission> _configuredPermissions() {
  final configured = Platform.environment['CONCLAVE_WORKER_PERMISSIONS'];
  if (configured == null || configured.trim().isEmpty) {
    // Desktop installs must work without shell-provided environment. This is
    // the machine-wide adapter admission ceiling only; each configured Worker
    // still has an explicit local permission set that Cloud cannot broaden.
    return WorkerPermission.values.toSet();
  }
  return parseConfiguredWorkerPermissions(configured);
}

WorkerTrustPolicy _releaseTrustPolicy(String publisher) {
  final secret = Platform.environment['CONCLAVE_HOST_RELEASE_TRUST_SECRET'];
  return WorkerTrustPolicy(
    trustedSecrets: secret == null ? {} : {publisher: secret},
  );
}

Future<Host> buildWorkspaceRuntime(
  HostConfig config, {
  List<String> restartArgs = const [],
}) async {
  final publisher =
      Platform.environment['CONCLAVE_WORKER_TRUST_PUBLISHER'] ?? 'conclave';
  final trustSecret = Platform.environment['CONCLAVE_WORKER_TRUST_SECRET'];
  final workerTrustPolicy = WorkerTrustPolicy(
    trustedSecrets: trustSecret == null ? {} : {publisher: trustSecret},
  );
  const credentialStore = PlatformSecureCredentialStore();
  final releaseTrustPolicy = _releaseTrustPolicy(publisher);
  final localWorkerRegistry = config.workspaceId == null
      ? null
      : LocalConfiguredWorkerRegistry(
          dataDirectory: config.dataDirectory,
          workspaceId: config.workspaceId!,
        );
  final v7AdapterPackageStore = V7AdapterPackageStore(
    root: Directory('${config.dataDirectory.path}/v7-adapters'),
    trustPolicy: workerTrustPolicy,
    allowedPermissions: _configuredPermissions(),
  );
  final activeWorkerIds = (await localWorkerRegistry?.list() ?? const [])
      .where((worker) => worker.status == LocalWorkerStatus.ready)
      .map((worker) => worker.id)
      .toList();
  final repositoryRegistry = await LocalRepositoryRegistry.load(File(
    config.repositoriesFile ?? '${config.dataDirectory.path}/repositories.json',
  ));
  final workerHandler = WorkerAssignmentHandler(
    executor: WorkerProcessExecutor(),
    resolve: (_) async => null,
    resolveV7Adapter: (workerId) async {
      final registry = localWorkerRegistry;
      if (registry == null) {
        throw StateError('Workspace-owned Worker inventory is unavailable');
      }
      final worker = await registry.find(workerId);
      if (worker == null) {
        throw StateError('Workspace-owned Worker is not present locally');
      }
      if (worker.status != LocalWorkerStatus.ready ||
          (worker.authStrategy == 'api_key' &&
              worker.credentialStatus != LocalWorkerCredentialStatus.ready)) {
        throw StateError('local Worker is not ready for execution');
      }
      final adapter = await v7AdapterPackageStore.resolve(
        worker: worker,
        readCredential: credentialStore.readSync,
      );
      if (adapter == null) {
        throw StateError(
            'no trusted adapter is installed for ${worker.workerTypeId}');
      }
      return adapter;
    },
    resolveRepositoryPath: repositoryRegistry.resolve,
    resolvePermissions: (workerId) async {
      final worker = await localWorkerRegistry?.find(workerId);
      if (worker == null) {
        throw StateError('Workspace-owned Worker is not present locally');
      }
      return {
        for (final permission in worker.localPermissions)
          ...switch (permission) {
            'workstream_filesystem' => {'workspace:read', 'workspace:write'},
            'shell_execution' => {'shell:execute'},
            'network' => {'network:outbound'},
            _ => {permission},
          },
      };
    },
    resolveConcurrencyLimit: (workerId) async {
      final worker = await localWorkerRegistry?.find(workerId);
      return worker?.localConcurrencyLimit;
    },
  );
  HostUpdateController? updateController;
  String? updateAvailable;
  var lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(0);
  if (config.cloudUri != null) {
    updateController = HostUpdateController(
      cloudUri: config.cloudUri!,
      currentVersion: '0.1.0',
      client: const HostReleaseClient(),
      updater: HostUpdater(
        Directory('${config.dataDirectory.path}/updates'),
        trustPolicy: releaseTrustPolicy,
      ),
      operatingSystem: Platform.operatingSystem,
      authToken: config.authToken,
    );
  }
  Future<void> refreshUpdateAvailability() async {
    if (updateController == null ||
        DateTime.now().difference(lastUpdateCheck) <
            const Duration(minutes: 5)) {
      return;
    }
    lastUpdateCheck = DateTime.now();
    try {
      final release = await updateController.check();
      updateAvailable = release?.version;
    } on Object {
      // Status remains useful while Cloud is offline; the next interval
      // retries the check.
    }
  }

  late final HostCloudConnection? connection;
  connection = config.cloudUri != null &&
          config.hostId != null &&
          config.workspaceId != null
      ? HostCloudConnection(
          uri: config.cloudUri!,
          hostId: config.hostId!,
          workspaceId: config.workspaceId!,
          activeWorkerIds: activeWorkerIds,
          assignmentHandler: workerHandler.call,
          assignmentCancellationHandler: workerHandler.cancel,
          workerInventoryProvider: () async {
            final localWorkers =
                await localWorkerRegistry?.list(includeRemoved: true) ??
                    const [];
            final lastSeenAt = DateTime.now().toUtc().toIso8601String();
            return Future.wait(localWorkers.map((worker) async {
              Map<String, Object?>? adapterSummary;
              try {
                adapterSummary =
                    await v7AdapterPackageStore.activeManifestSummary(worker);
              } on Object {
                // Invalid, revoked, or permission-incompatible packages must
                // not be advertised as active in the safe inventory.
              }
              return <String, Object?>{
                'workerId': worker.id,
                'workerTypeId': worker.workerTypeId,
                'name': worker.name,
                'status': switch (worker.status) {
                  LocalWorkerStatus.ready => 'ready',
                  LocalWorkerStatus.needsAttention => 'needs_attention',
                  LocalWorkerStatus.disabled => 'disabled',
                  LocalWorkerStatus.removed => 'removed',
                },
                'authStrategy': worker.authStrategy,
                'defaultModel': worker.defaultModel,
                'allowedModels': worker.allowedModels,
                'capabilities':
                    adapterSummary?['capabilities'] ?? const <String>[],
                'localPermissionsSummary': worker.localPermissions,
                'localConcurrencyLimit': worker.localConcurrencyLimit,
                // This records configured policy only when a concrete
                // adapter build has been admitted and activated.
                'adapterVersion': adapterSummary?['adapterVersion'],
                'credentialStatus': switch (worker.credentialStatus) {
                  LocalWorkerCredentialStatus.notRequired => 'not_required',
                  LocalWorkerCredentialStatus.ready => 'ready',
                  LocalWorkerCredentialStatus.needsAuthentication =>
                    'needs_authentication',
                  LocalWorkerCredentialStatus.expired => 'expired',
                  LocalWorkerCredentialStatus.error => 'error',
                },
                'revision': worker.revision,
                'createdAt': worker.createdAt,
                'updatedAt': worker.updatedAt,
                'lastSeenAt': lastSeenAt,
              };
            }).toList());
          },
          hostUpdateAvailableHandler: (payload) async {
            final controller = updateController;
            if (controller == null) return;
            final release = controller.acceptAvailable(payload);
            updateAvailable = release.version;
          },
          assignmentJournal: AssignmentJournal(
            File('${config.dataDirectory.path}/assignments.jsonl'),
          ),
          factory: (uri) => connectIoHostCloudSocket(
            uri,
            authToken: config.authToken,
          ),
        )
      : null;
  final engine = Host(
    config: config,
    cloudConnection: connection,
    adapterPackageStore: v7AdapterPackageStore,
    statusProvider: () async {
      await refreshUpdateAvailability();
      final workers = await localWorkerRegistry?.list() ?? const [];
      return {
        'workers': workers.length,
        'workerIds': workers.map((worker) => worker.id).toList(),
        'activeTasks': connection?.activeAssignmentCount ?? 0,
        'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        'cloudConnected': connection?.isConnected ?? false,
        if (updateAvailable != null) 'updateAvailable': updateAvailable,
      };
    },
    updateStatusProvider: () async =>
        updateController?.status.toJson() ?? const {'phase': 'unconfigured'},
    updateHandler: (request) async {
      final controller = updateController;
      if (controller == null) {
        throw StateError('Host updates are not configured');
      }
      final action = request['action'] as String? ?? 'status';
      if (action == 'check') {
        final release = await controller.check();
        updateAvailable = release?.version;
      } else if (action == 'apply') {
        await controller.apply(
          hasActiveAssignments: () async =>
              (connection?.activeAssignmentCount ?? 0) > 0,
          healthCheck: (executable) async =>
              await executable.exists() && await executable.length() > 0,
          restartBootstrap: (executable) async {
            try {
              await Process.start(
                executable.path,
                restartArgs,
                mode: ProcessStartMode.detachedWithStdio,
              );
              // Allow the IPC response to flush and release the engine lock
              // before the replacement process starts using the same data
              // directory.
              unawaited(Future<void>.delayed(
                const Duration(milliseconds: 150),
                () => exit(0),
              ));
              return true;
            } on Object {
              return false;
            }
          },
        );
        updateAvailable = controller.availableRelease?.version;
      } else if (action != 'status') {
        throw StateError('unsupported Host update action: $action');
      }
      return controller.status.toJson();
    },
  );
  return engine;
}
