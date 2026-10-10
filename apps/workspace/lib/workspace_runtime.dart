import 'development_tool_profiles.dart';
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
import 'package:conclave_workspace/self_update.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/desktop_auth.dart';
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
  String? humanAuthToken;
  // A human session is only needed to sync the catalog while a saved Cloud
  // endpoint exists without a registered runtime identity. Avoid invoking
  // the OS credential helper for a fresh, offline service installation.
  if (config.workspaceRuntimeId == null && config.cloudUri != null) {
    try {
      final stored =
          await secureCredentialStore.read(desktopHumanCredentialKey);
      if (stored != null && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is Map) {
          final session = DesktopHumanSession.fromSecureJson(
            Map<String, dynamic>.from(decoded),
          );
          if (session.expiresAt.isAfter(DateTime.now().toUtc())) {
            humanAuthToken = session.credential;
          }
        }
      }
    } on Object {
      // A missing or expired desktop session simply leaves the disconnected
      // Workspace on its local catalog cache.
    }
  }
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
  late final WorkerCatalogCoordinator? workerCatalogCoordinator;
  final localWorkerRegistry = LocalWorkerRegistry(
    dataDirectory: effectiveConfig.dataDirectory,
    workspaceId: localWorkspaceId,
    onChanged: () async {
      await workerCatalogCoordinator?.refreshLocalWorkers();
      await connection?.refreshWorkerInventory();
    },
    onWorkerRemoving: (workerId) async {
      await cliWorkerEngineSupervisor?.cancelWorker(workerId);
    },
  );
  const developmentDraftRoot =
      String.fromEnvironment('CONCLAVE_DEVELOPMENT_PROFILE_DIRECTORY');
  DevelopmentToolProfiles? developmentProfiles;
  if (developmentDraftRoot.isNotEmpty) {
    final cloudUri = effectiveConfig.cloudUri;
    if (cloudUri == null) {
      throw StateError(
          'Unsigned development Profiles require a loopback Cloud connection');
    }
    developmentProfiles = DevelopmentToolProfiles(
      draftsRoot: Directory(developmentDraftRoot),
      snapshotsRoot: Directory(
          '${config.dataDirectory.absolute.path}/development_profiles'),
      cloudUri: cloudUri,
      releaseBuild: const bool.fromEnvironment('dart.vm.product'),
    );
  }
  final toolProfileReleaseStore = ToolProfileReleaseStore(
    profilesRoot: WorkspacePaths(config.dataDirectory).profilesDirectory,
    trustPolicy: workerTrustPolicy,
    developmentProfiles: developmentProfiles,
  );
  final bundledEngine = await loadBundledCliWorkerEngine(
    enginesDirectory: workspacePaths.enginesDirectory,
  );
  cliWorkerEngineSupervisor = bundledEngine == null
      ? null
      : CliWorkerEngineSupervisor(
          engineExecutable: bundledEngine.path,
          processRegistryDirectory: workspacePaths.runtimeDirectory,
        );
  late final WorkerReadinessMonitor readinessMonitor;
  final toolProfileCatalog = config.cloudUri == null
      ? null
      : ToolProfileCatalogClient(
          cloudUri: config.cloudUri!,
          store: toolProfileReleaseStore,
          trustPolicy: workerTrustPolicy,
          workspaceRuntimeId: config.workspaceRuntimeId,
          authToken: config.authToken,
          humanAuthToken: humanAuthToken,
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
  if (toolProfileCatalog != null) {
    workerCatalogCoordinator = WorkerCatalogCoordinator(
      catalog: toolProfileCatalog,
      releaseStore: toolProfileReleaseStore,
      registry: localWorkerRegistry,
      onCatalogReconciled: () async {
        await connection?.refreshWorkerInventory();
      },
      refreshReadiness: () => readinessMonitor
          .checkNow(
            mode: LocalWorkerProbeMode.passive,
            rerunWhenActive: true,
          )
          .then((_) => connection?.refreshWorkerInventory()),
    );
  } else {
    workerCatalogCoordinator = null;
  }
  final activeWorkerIds = (await localWorkerRegistry.list())
      .where((worker) => worker.status == LocalWorkerStatus.ready)
      .map((worker) => worker.id)
      .toList();
  final workRoot = await config.workRootResolver.resolve();
  workspacePaths.validateWorkRootSeparation(workRoot);
  final spaceDirectoryLifecycle = SpaceDirectoryLifecycle(
    SpaceDirectoryResolver(
      workRoot: workRoot,
      registryDirectory: workspacePaths.spaceDirectoryRegistryDirectory,
    ),
  );
  final workerHandler = WorkerAssignmentHandler(
    resolveLogicalWorker: (workerId) async {
      final worker = await localWorkerRegistry.find(workerId);
      if (worker == null) {
        return null;
      }
      final catalogEntry = await workerCatalogCoordinator
          ?.ensureCatalogEntry(worker.workerTypeId);
      final catalogAvailable =
          workerCatalogCoordinator == null || catalogEntry != null;
      return AssignmentLogicalWorker(
        id: worker.id,
        workerTypeId: worker.workerTypeId,
        enabled: catalogAvailable &&
            worker.activationState == LocalWorkerActivationState.enabled,
        ready: catalogAvailable && worker.status == LocalWorkerStatus.ready,
        permissions: worker.localPermissions.toSet(),
        localConcurrencyLimit: worker.localConcurrencyLimit,
        providerCliVersion: worker.toolVersion,
      );
    },
    defaultWorkingDirectory: workRoot,
    applicationStateDirectory: workspacePaths.applicationSupportDirectory,
    spaceDirectoryLifecycle: spaceDirectoryLifecycle,
    cancelToolProfileAssignment: cliWorkerEngineSupervisor?.cancel,
    executeWithToolProfile: (worker, workingDirectory, context, payload,
        {onProgress}) async {
      final supervisor = cliWorkerEngineSupervisor;
      final coordinator = workerCatalogCoordinator;
      if (coordinator == null || supervisor == null) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message: executionErrorMessage('worker_not_ready'),
        );
      }
      final resolution = await coordinator.resolveProfileForWorker(
        workerTypeId: worker.workerTypeId,
        engineVersion: cliWorkerEngineVersion,
        providerCliVersion: worker.providerCliVersion,
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
      final workerSessionValue = payload['workerSession'];
      final workerSession = workerSessionValue == null
          ? null
          : WorkerSessionContext.fromJson(
              Map<String, Object?>.from(workerSessionValue as Map));
      final input = payload['input'];
      final modelValue =
          payload['model'] ?? (input is Map ? input['model'] : null);
      final reasoningEffortValue = payload['reasoningEffort'] ??
          (input is Map ? input['reasoningEffort'] : null);
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
      final profileFile =
          await toolProfileReleaseStore.executionProfileFile(release);
      final profilePayload =
          jsonDecode(await profileFile.readAsString()) as Map;
      if (!profileAllowsAssignment(
          payload, (profilePayload['capabilities'] as List).cast<String>())) {
        throw AssignmentExecutionFailure(
          code: 'worker_not_ready',
          message:
              'This Profile has no verified read-only execution policy. Select a compatible Worker for Chat.',
        );
      }
      return supervisor.execute(
        release,
        profileFile: profileFile,
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
        workerSession: workerSession,
        statelessContext: payload["statelessContext"] == null
            ? null
            : ConversationBootstrap.fromJson(
                Map<String, Object?>.from(payload["statelessContext"] as Map)),
        model: modelValue is String && modelValue.trim().isNotEmpty
            ? modelValue.trim()
            : null,
        reasoningEffort: reasoningEffortValue is String &&
                reasoningEffortValue.trim().isNotEmpty
            ? reasoningEffortValue.trim()
            : null,
        executionPolicy: assignmentExecutionPolicy(context.payload),
        onProgress: onProgress,
      );
    },
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
            return workerCatalogCoordinator?.inventoryForWorkers(
                  localWorkers,
                  engineVersion: cliWorkerEngineVersion,
                  engineAvailable: cliWorkerEngineSupervisor != null,
                ) ??
                const <Map<String, Object?>>[];
          },
          onSessionReady: () async {
            await workerCatalogCoordinator?.refresh(force: true);
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
    workerCatalogCoordinator: workerCatalogCoordinator,
    cliWorkerEngineSupervisor: cliWorkerEngineSupervisor,
    workerStateDirectory: workspacePaths.workerStateDirectory,
    profileDiagnosticStoreForWorker: (workerTypeId) => WorkerDiagnosticStore(
      directory: Directory(
        '${workspacePaths.workerStateDirectory(workerTypeId).parent.path}'
        '${Platform.pathSeparator}logs',
      ),
    ),
  );
  final engine = Workspace(
    config: effectiveConfig,
    credentialStore: secureCredentialStore,
    localWorkerRegistry: localWorkerRegistry,
    workerReadinessMonitor: readinessMonitor,
    workerShutdownHandler: () async {
      await cliWorkerEngineSupervisor?.shutdown();
    },
    workerRecoveryHandler: () async =>
        await cliWorkerEngineSupervisor?.recoverOrphanedProcesses() ?? 0,
    cloudConnection: connection,
    toolProfileReleaseStore: toolProfileReleaseStore,
    toolProfileCatalog: toolProfileCatalog,
    workerCatalogCoordinator: workerCatalogCoordinator,
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
