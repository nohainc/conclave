import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/assignment_journal.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/workstream_directory.dart';
import 'package:conclave_workspace/workstream_path.dart';
import 'package:conclave_workspace/self_update.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace_registration.dart';
import 'package:conclave_workspace/workspace_transport.dart';
import 'package:conclave_workspace/worker_readiness.dart';
import 'package:conclave_workspace/bundled_cli_worker_engine_loader.dart';
import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/worker_diagnostic_store.dart';
import 'package:conclave_workspace/tool_profile_resolver.dart';

Future<Workspace> buildWorkspaceRuntime(
  WorkspaceConfig config, {
  List<String> restartArgs = const [],
  SecureCredentialStore? credentialStore,
}) async {
  final workerTrustPolicy = workspaceReleaseTrustPolicy();
  final workspacePaths = WorkspacePaths(config.dataDirectory);
  final secureCredentialStore =
      credentialStore ?? const PlatformSecureCredentialStore();
  final releaseTrustPolicy = workerTrustPolicy;
  CliWorkerEngineSupervisor? cliWorkerEngineSupervisor;
  final installationId = await InstallationIdentityStore(
    config.dataDirectory,
  ).getOrCreate(initialIdentity: config.installationId);
  final effectiveConfig = config.installationId == installationId
      ? config
      : WorkspaceConfig(
          dataDirectory: config.dataDirectory,
          cloudUri: config.cloudUri,
          workspaceRuntimeId: config.workspaceRuntimeId,
          installationId: installationId,
          workspaceId: config.workspaceId,
          authToken: config.authToken,
          workRootPath: config.workRootPath,
        );
  final localWorkspaceId = await LocalWorkspaceIdentityStore(
    effectiveConfig.dataDirectory,
  ).getOrCreate(initialIdentity: effectiveConfig.workspaceId);
  WorkspaceCloudConnection? connection;
  final localWorkerRegistry = LocalWorkerRegistry(
    dataDirectory: effectiveConfig.dataDirectory,
    workspaceId: localWorkspaceId,
    onChanged: () async {
      await connection?.refreshWorkerInventory();
    },
    onWorkerRemoving: (workerId) async {
      await cliWorkerEngineSupervisor?.cancelWorker(workerId);
    },
  );
  final toolProfileReleaseStore = ToolProfileReleaseStore(
    profilesRoot: WorkspacePaths(config.dataDirectory).profilesDirectory,
    trustPolicy: workerTrustPolicy,
  );
  final bundledEngine = await loadBundledCliWorkerEngine(
    enginesDirectory: workspacePaths.enginesDirectory,
  );
  cliWorkerEngineSupervisor = bundledEngine == null
      ? null
      : CliWorkerEngineSupervisor(engineExecutable: bundledEngine.path);
  late final WorkerReadinessMonitor readinessMonitor;
  final toolProfileCatalog = config.cloudUri == null
      ? null
      : ToolProfileCatalogClient(
          cloudUri: config.cloudUri!,
          store: toolProfileReleaseStore,
          trustPolicy: workerTrustPolicy,
          workspaceRuntimeId: config.workspaceRuntimeId,
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
  final workRoot = await config.workRootResolver.resolve();
  final workerHandler = WorkerAssignmentHandler(
    resolveLogicalWorker: (workerId) async {
      final worker = await localWorkerRegistry.find(workerId);
      if (worker == null) return null;
      return AssignmentLogicalWorker(
        id: worker.id,
        workerTypeId: worker.workerTypeId,
        enabled: worker.activationState == LocalWorkerActivationState.enabled,
        ready: worker.status == LocalWorkerStatus.ready,
        permissions: worker.localPermissions.toSet(),
        localConcurrencyLimit: worker.localConcurrencyLimit,
        providerCliVersion: worker.toolVersion,
      );
    },
    defaultWorkingDirectory: workRoot,
    cancelToolProfileAssignment: cliWorkerEngineSupervisor?.cancel,
    executeWithToolProfile: (worker, workingDirectory, context, payload,
        {onProgress}) async {
      var profileDefinitionId =
          toolProfileCatalog?.profileDefinitionForWorker(worker.workerTypeId);
      if (profileDefinitionId == null && toolProfileCatalog != null) {
        try {
          await toolProfileCatalog.syncCatalog();
        } on Object {
          // Verified local releases remain usable if Cloud is unavailable.
        }
        profileDefinitionId =
            toolProfileCatalog.profileDefinitionForWorker(worker.workerTypeId);
      }
      final supervisor = cliWorkerEngineSupervisor;
      if (profileDefinitionId == null || supervisor == null) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      final resolver = ToolProfileResolver(toolProfileReleaseStore);
      final resolution = await resolver.resolveForWorker(
        logicalWorkerTypeId: worker.workerTypeId,
        profileDefinitionId: profileDefinitionId,
        engineVersion: cliWorkerEngineVersion,
        providerCliVersion: worker.providerCliVersion,
        ensureAvailable: () async {
          await toolProfileCatalog?.syncCatalog();
          await toolProfileCatalog?.syncWorkerProfiles(worker.workerTypeId);
        },
      );
      final release = resolution.release;
      if (release == null) {
        throw AssignmentExecutionFailure(
          code: resolution.reason ==
                  ToolProfileUnavailableReason.unsupportedProviderVersion
              ? 'unsupported_provider_tool_version'
              : 'worker_not_ready',
          message: executionErrorMessage(
            resolution.reason ==
                    ToolProfileUnavailableReason.unsupportedProviderVersion
                ? 'unsupported_provider_tool_version'
                : 'worker_not_ready',
          ),
        );
      }
      final input = payload['input'];
      final modelValue =
          payload['model'] ?? (input is Map ? input['model'] : null);
      final sessionPolicyValue = payload['sessionPolicy'] ??
          (input is Map ? input['sessionPolicy'] : null) ??
          'stateless';
      final sessionKeyValue =
          payload['sessionKey'] ?? (input is Map ? input['sessionKey'] : null);
      if (!const {'stateless', 'durable_session'}
              .contains(sessionPolicyValue) ||
          (sessionPolicyValue == 'durable_session') !=
              (sessionKeyValue is String)) {
        throw AssignmentExecutionFailure(
          code: 'execution_failed',
          message: executionErrorMessage('execution_failed'),
        );
      }
      final prompt = input is Map && input['prompt'] is String
          ? input['prompt'] as String
          : payload['prompt'] is String
              ? payload['prompt'] as String
              : jsonEncode(payload);
      final timeoutValue = payload['timeoutMs'];
      if (timeoutValue is! int || timeoutValue < 1) {
        throw AssignmentExecutionFailure(
          code: 'execution_failed',
          message: executionErrorMessage('execution_failed'),
        );
      }
      return supervisor.execute(
        release,
        profileFile: toolProfileReleaseStore.profileFile(
          release.profileDefinitionId,
          release.releaseVersion,
        ),
        stateDirectory: workspacePaths.workerStateDirectory(worker.id),
        workingDirectory: workingDirectory,
        workerId: worker.id,
        maxConcurrentAssignments: worker.localConcurrencyLimit,
        assignmentId: context.assignmentId,
        prompt: prompt,
        timeout: Duration(milliseconds: timeoutValue),
        sessionPolicy: sessionPolicyValue == 'durable_session'
            ? WorkerSessionPolicy.durableSession
            : WorkerSessionPolicy.stateless,
        sessionKey: sessionKeyValue as String?,
        model: modelValue is String && modelValue.trim().isNotEmpty
            ? modelValue.trim()
            : null,
        executionPolicy: context.payload['readOnly'] == true ||
                context.payload['executionClass'] == 'stateless_read'
            ? WorkerExecutionPolicy.providerDefault
            : WorkerExecutionPolicy.restricted,
        onProgress: onProgress,
      );
    },
    workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(workRoot),
    ),
  );
  WorkspaceUpdateController? updateController;
  String? updateAvailable;
  var lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(0);
  if (config.cloudUri != null) {
    updateController = WorkspaceUpdateController(
      cloudUri: config.cloudUri!,
      currentVersion: conclaveWorkspaceAppVersion,
      client: const WorkspaceReleaseClient(),
      updater: WorkspaceUpdater(
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
          config.workspaceRuntimeId != null &&
          config.workspaceId != null
      ? WorkspaceCloudConnection(
          uri: config.cloudUri!,
          workspaceRuntimeId: config.workspaceRuntimeId!,
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
          workspaceUpdateAvailableHandler: (payload) async {
            final controller = updateController;
            if (controller == null) return;
            final release = controller.acceptAvailable(payload);
            updateAvailable = release.version;
          },
          assignmentJournal: AssignmentJournal(
            File('${config.dataDirectory.path}/assignments.jsonl'),
          ),
          factory: (uri) => connectWebSocketWorkspaceTransport(
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
              workspaceRuntimeId: config.workspaceRuntimeId!,
              runtimeCredential: config.authToken!,
            );
          },
        )
      : null;
  readinessMonitor = WorkerReadinessMonitor(
    registry: localWorkerRegistry,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    cliWorkerEngineSupervisor: cliWorkerEngineSupervisor,
    workerStateDirectory: workspacePaths.workerStateDirectory,
    profileDiagnosticStoreForWorker: (workerTypeId) => WorkerDiagnosticStore(
      directory: Directory(
        '${workspacePaths.workerStateDirectory(workerTypeId).parent.path}'
        '${Platform.pathSeparator}logs',
      ),
    ),
    ensureToolProfileAvailable: (workerTypeId) async {
      await toolProfileCatalog?.syncCatalog();
      await toolProfileCatalog?.syncWorkerProfiles(workerTypeId);
    },
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
  final engine = Workspace(
    config: effectiveConfig,
    credentialStore: secureCredentialStore,
    localWorkerRegistry: localWorkerRegistry,
    workerReadinessMonitor: readinessMonitor,
    workerShutdownHandler: () async {
      await cliWorkerEngineSupervisor?.shutdown();
    },
    cloudConnection: connection,
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
        throw StateError('Workspace updates are not configured');
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
        throw StateError('unsupported Workspace update action: $action');
      }
      return controller.status.toJson();
    },
  );
  return engine;
}
