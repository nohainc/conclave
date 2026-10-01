import 'dart:async';
import 'dart:io';

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_host/host.dart';
import 'package:conclave_host/bundled_adapter_asset_loader.dart';
import 'package:conclave_host/host_configuration.dart';
import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/first_party_worker_registry.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:conclave_host/repository_registry.dart';
import 'package:conclave_host/self_update.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/v7_adapter_catalog.dart';
import 'package:conclave_host/workspace_enrollment.dart';
import 'package:conclave_host/workspace_transport.dart';
import 'package:conclave_host/worker_readiness.dart';
import 'package:conclave_host/worker_process_supervisor.dart';
import 'package:conclave_host/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_host/cli_worker_engine_supervisor.dart';
import 'package:conclave_host/worker_diagnostic_store.dart';

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

Future<Host> buildWorkspaceRuntime(
  HostConfig config, {
  List<String> restartArgs = const [],
  SecureCredentialStore? credentialStore,
}) async {
  final workerTrustPolicy = workspaceReleaseTrustPolicy();
  final workspacePaths = WorkspacePaths(config.dataDirectory);
  final secureCredentialStore =
      credentialStore ?? const PlatformSecureCredentialStore();
  final workerExecutor = WorkerProcessExecutor();
  final releaseTrustPolicy = workerTrustPolicy;
  final nativeWorkerSupervisor = WorkerProcessSupervisor();
  final installationId = await InstallationIdentityStore(
    config.dataDirectory,
  ).getOrCreate(initialIdentity: config.installationId);
  final effectiveConfig = config.installationId == installationId
      ? config
      : HostConfig(
          dataDirectory: config.dataDirectory,
          cloudUri: config.cloudUri,
          hostId: config.hostId,
          installationId: installationId,
          workspaceId: config.workspaceId,
          repositoriesFile: config.repositoriesFile,
          authToken: config.authToken,
          workRootPath: config.workRootPath,
        );
  final localWorkspaceId = await LocalWorkspaceIdentityStore(
    effectiveConfig.dataDirectory,
  ).getOrCreate(initialIdentity: effectiveConfig.workspaceId);
  HostCloudConnection? connection;
  final localWorkerRegistry = LocalConfiguredWorkerRegistry(
    dataDirectory: effectiveConfig.dataDirectory,
    workspaceId: localWorkspaceId,
    onChanged: () async {
      await connection?.refreshWorkerInventory();
    },
    onWorkerRemoving: (workerId) async {
      await workerExecutor.cancelWorker(workerId);
    },
    onLegacyCredentialReference: secureCredentialStore.delete,
  );
  final v7AdapterPackageStore = V7AdapterPackageStore(
    root: WorkspacePaths(config.dataDirectory).adaptersDirectory,
    workerStateRoot: WorkspacePaths(config.dataDirectory).workersDirectory,
    statePlatform: WorkspacePaths(config.dataDirectory).platform,
    trustPolicy: workerTrustPolicy,
    allowedPermissions: _configuredPermissions(),
    loadBundledPackage: loadBundledFirstPartyAdapter,
  );
  final adapterCatalog = config.cloudUri == null
      ? null
      : V7AdapterCatalogClient(
          cloudUri: config.cloudUri!,
          packageStore: v7AdapterPackageStore,
          authToken: config.authToken,
        );
  final workerVersionStore = WorkerVersionStore(
    workersRoot: WorkspacePaths(config.dataDirectory).workersDirectory,
    trustPolicy: workerTrustPolicy,
    allowedPermissions: _configuredPermissions(),
    workerStateSchemaVersion: 1,
    hasActiveAssignments: () => (connection?.activeAssignmentCount ?? 0) > 0,
    candidateHealthCheck: WorkerCandidateValidator(
      supervisor: nativeWorkerSupervisor,
    ),
  );
  final workerReleaseCatalog = config.cloudUri == null
      ? null
      : WorkerReleaseCatalog(
          cloudUri: config.cloudUri!,
          store: workerVersionStore,
          authToken: config.authToken,
          hasActiveAssignments: () =>
              (connection?.activeAssignmentCount ?? 0) > 0,
        );
  final toolProfileReleaseStore = ToolProfileReleaseStore(
    profilesRoot: WorkspacePaths(config.dataDirectory).profilesDirectory,
    trustPolicy: workerTrustPolicy,
  );
  final bundledEngine = await loadBundledCliWorkerEngine(
    enginesDirectory: workspacePaths.enginesDirectory,
  );
  final cliWorkerEngineSupervisor = bundledEngine == null
      ? null
      : CliWorkerEngineSupervisor(engineExecutable: bundledEngine.path);
  late final WorkerReadinessMonitor readinessMonitor;
  final toolProfileCatalog = config.cloudUri == null
      ? null
      : ToolProfileCatalogClient(
          cloudUri: config.cloudUri!,
          store: toolProfileReleaseStore,
          trustPolicy: workerTrustPolicy,
          workspaceRuntimeId: config.hostId,
          authToken: config.authToken,
          candidateValidator: (candidate, profileFile) async {
            final supervisor = cliWorkerEngineSupervisor;
            if (supervisor == null) return false;
            final workers = (await localWorkerRegistry.list())
                .where((worker) =>
                    worker.workerTypeId == candidate.logicalWorkerTypeId)
                .toList();
            if (workers.isEmpty) return false;
            final worker = workers.first;
            final result = await supervisor.probe(
              candidate,
              profileFile: profileFile,
              stateDirectory: workspacePaths.workerStateDirectory(worker.id),
              mode: WorkerProbeMode.passive,
              timeout: const Duration(seconds: 20),
            );
            return result.ready;
          },
          onRevocationsApplied: (workerTypeIds) async {
            for (final workerTypeId in workerTypeIds) {
              unawaited(readinessMonitor
                  .checkNow(
                    mode: LocalWorkerProbeMode.passive,
                    workerTypeId: workerTypeId,
                    includeDisabled: true,
                  )
                  .catchError((_) {}));
            }
          },
        );
  final activeWorkerIds = (await localWorkerRegistry.list())
      .where((worker) => worker.status == LocalWorkerStatus.ready)
      .map((worker) => worker.id)
      .toList();
  final repositoryRegistry = await LocalRepositoryRegistry.load(File(
    config.repositoriesFile ?? '${config.dataDirectory.path}/repositories.json',
  ));
  final workRoot = await config.workRootResolver.resolve();
  final workerHandler = WorkerAssignmentHandler(
    executor: workerExecutor,
    resolve: (_) async => null,
    resolveV7Adapter: (workerId, {expectedWorkerTypeId}) async {
      final worker = await localWorkerRegistry.find(workerId);
      if (worker == null) {
        throw V7AdapterExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      if (expectedWorkerTypeId != null &&
          worker.workerTypeId != expectedWorkerTypeId) {
        throw V7AdapterExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      if (worker.status != LocalWorkerStatus.ready) {
        throw V7AdapterExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      final descriptor =
          FirstPartyWorkerPackage.forProductWorkerTypeId(worker.workerTypeId);
      if (descriptor != null && expectedWorkerTypeId == null) {
        throw V7AdapterExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      final adapter = await v7AdapterPackageStore.resolve(
        worker: worker,
        readCredential: secureCredentialStore.read,
      );
      if (adapter == null) {
        throw V7AdapterExecutionFailure(
          code: 'internal_adapter_error',
          message: executionErrorMessage('internal_adapter_error'),
        );
      }
      return adapter;
    },
    resolveRepositoryPath: repositoryRegistry.resolve,
    resolvePermissions: (workerId) async {
      final worker = await localWorkerRegistry.find(workerId);
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
      final worker = await localWorkerRegistry.find(workerId);
      return worker?.localConcurrencyLimit;
    },
    workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(workRoot),
    ),
  );
  HostUpdateController? updateController;
  String? updateAvailable;
  var lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(0);
  if (config.cloudUri != null) {
    updateController = HostUpdateController(
      cloudUri: config.cloudUri!,
      currentVersion: conclaveWorkspaceAppVersion,
      client: const HostReleaseClient(),
      updater: HostUpdater(
        WorkspacePaths(config.dataDirectory).updatesDirectory,
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

  connection = config.cloudUri != null &&
          config.hostId != null &&
          config.workspaceId != null
      ? HostCloudConnection(
          uri: config.cloudUri!,
          hostId: config.hostId!,
          workspaceId: config.workspaceId!,
          credentialAvailable: config.authToken?.isNotEmpty == true,
          activeWorkerIds: activeWorkerIds,
          assignmentHandler: workerHandler.call,
          assignmentCancellationHandler: workerHandler.cancel,
          workerInventoryProvider: () async {
            final localWorkers = await localWorkerRegistry.list();
            final lastSeenAt = DateTime.now().toUtc().toIso8601String();
            return Future.wait(localWorkers.map((worker) async {
              final catalogEntry =
                  toolProfileCatalog?.entryForWorker(worker.workerTypeId);
              final definitionId = catalogEntry?.profileDefinitionId;
              ToolProfileReleaseAdmission? activeProfile;
              if (definitionId != null) {
                try {
                  activeProfile =
                      await toolProfileReleaseStore.activeRelease(definitionId);
                } on Object {
                  // Missing or revoked Profile evidence is reported as absent.
                }
              }
              final declaredCapabilities =
                  catalogEntry?.capabilities ?? const <String>[];
              final capabilities = <String>{
                ...declaredCapabilities,
                if (declaredCapabilities.contains('workstream_read'))
                  'authorized_context_read',
              }.toList()
                ..sort();
              return <String, Object?>{
                'workerId': worker.id,
                'workerTypeId': worker.workerTypeId,
                'activationState': worker.activationState ==
                        LocalWorkerActivationState.disabled
                    ? 'disabled'
                    : 'enabled',
                'readinessState': worker.readinessState.wireValue,
                if (worker.readinessIssueCode != null)
                  'readinessIssueCode': worker.readinessIssueCode,
                'engineVersion': cliWorkerEngineVersion,
                'profileDefinitionId': definitionId,
                'profileReleaseVersion': activeProfile?.releaseVersion,
                'providerToolName':
                    worker.toolName ?? catalogEntry?.providerToolName,
                'providerToolVersion': worker.toolVersion,
                'capabilities': capabilities,
                'localConcurrencyLimit': worker.localConcurrencyLimit,
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
          fallbackFactory: (uri) {
            final gatewayPath = uri.path.indexOf('/api/workspace-gateway');
            final basePath =
                gatewayPath < 0 ? '' : uri.path.substring(0, gatewayPath);
            final baseUri = uri.replace(
              scheme: uri.scheme == 'wss' ? 'https' : 'http',
              path: basePath,
              query: null,
              fragment: null,
            );
            return HttpLongPollWorkspaceTransport.connect(
              baseUri: baseUri,
              workspaceRuntimeId: config.hostId!,
              runtimeCredential: config.authToken!,
            );
          },
        )
      : null;
  if (adapterCatalog != null) {
    var reconcilingAdapters = false;
    Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(() async {
        if (reconcilingAdapters) return;
        reconcilingAdapters = true;
        try {
          final canActivate = (connection?.activeAssignmentCount ?? 0) == 0;
          final workers = await localWorkerRegistry.list();
          for (final worker in workers.where((item) =>
              item.status == LocalWorkerStatus.ready &&
              item.adapterVersionPolicy != null)) {
            await adapterCatalog.reconcileWorker(
              FirstPartyWorkerPackage.packageIdFor(
                worker.workerTypeId,
              ),
              channel:
                  worker.adapterVersionPolicy == 'beta' ? 'beta' : 'stable',
              allowActivation: canActivate,
            );
          }
          await connection?.refreshWorkerInventory();
        } on Object {
          // Preserve the last usable adapter and retry on the next interval.
        } finally {
          reconcilingAdapters = false;
        }
      }());
    });
  }
  if (workerReleaseCatalog != null) {
    var refreshingWorkerReleases = false;
    Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(() async {
        if (refreshingWorkerReleases ||
            (connection?.activeAssignmentCount ?? 0) > 0) {
          return;
        }
        refreshingWorkerReleases = true;
        try {
          for (final descriptor in FirstPartyWorkerPackage.all) {
            await workerReleaseCatalog.refreshAutomaticUpdate(
              descriptor.productWorkerTypeId,
            );
          }
        } on Object {
          // Keep the installed Worker and retry at the next interval.
        } finally {
          refreshingWorkerReleases = false;
        }
      }());
    });
  }
  readinessMonitor = WorkerReadinessMonitor(
    registry: localWorkerRegistry,
    adapterStore: v7AdapterPackageStore,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    cliWorkerEngineSupervisor: cliWorkerEngineSupervisor,
    workerStateDirectory: workspacePaths.workerStateDirectory,
    profileDiagnosticStoreForWorker: (workerTypeId) => WorkerDiagnosticStore(
      directory: workerVersionStore.logsDirectory(workerTypeId),
    ),
    ensureToolProfileAvailable: (workerTypeId) async {
      await toolProfileCatalog?.syncCatalog();
      await toolProfileCatalog?.syncWorkerProfiles(workerTypeId);
    },
    executor: workerExecutor,
    readCredential: secureCredentialStore.read,
  );
  if (toolProfileCatalog != null) {
    var refreshingToolProfiles = false;
    Future<void> refreshToolProfiles() async {
      if (refreshingToolProfiles) return;
      refreshingToolProfiles = true;
      try {
        await toolProfileCatalog.loadCatalog();
        List<LogicalWorkerCatalogEntry> workers;
        try {
          workers = await toolProfileCatalog.syncCatalog();
        } on Object {
          workers = toolProfileCatalog.workers;
        }
        for (final worker in workers) {
          final workerTypeId = worker.workerTypeId;
          await toolProfileCatalog.syncWorkerProfiles(workerTypeId);
        }
      } on Object {
        // Keep verified cached Profiles usable and retry on the next interval.
      } finally {
        refreshingToolProfiles = false;
      }
    }

    Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(refreshToolProfiles());
    });
    unawaited(refreshToolProfiles());
  }
  final engine = Host(
    config: effectiveConfig,
    credentialStore: secureCredentialStore,
    localWorkerRegistry: localWorkerRegistry,
    workerReadinessMonitor: readinessMonitor,
    workerShutdownHandler: workerExecutor.shutdown,
    cloudConnection: connection,
    adapterPackageStore: v7AdapterPackageStore,
    workerVersionStore: workerVersionStore,
    workerReleaseCatalog: workerReleaseCatalog,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    statusProvider: () async {
      await refreshUpdateAvailability();
      final workers = await localWorkerRegistry.list();
      return {
        'appVersion': conclaveWorkspaceAppVersion,
        'workers': workers.length,
        'workerIds': workers.map((worker) => worker.id).toList(),
        'activeTasks': connection?.activeAssignmentCount ?? 0,
        'activeAssignmentIds': connection?.activeAssignmentIds ?? const [],
        'cloudConnected': connection?.isConnected ?? false,
        'lastUpdateCheckAt': lastUpdateCheck.toUtc().toIso8601String(),
        'lastUpdateCheckStatus':
            updateController?.status.phase ?? 'unconfigured',
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
