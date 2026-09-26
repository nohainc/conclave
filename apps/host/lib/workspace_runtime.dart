import 'dart:async';
import 'dart:io';

import 'package:conclave_host/host.dart';
import 'package:conclave_host/assignment_journal.dart';
import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/worker_manager.dart';
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

Map<String, String> _workerSecrets() {
  const store = PlatformSecureCredentialStore();
  final secrets = <String, String>{};
  for (final name in const [
    'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY',
    'CONCLAVE_CONNECTOR_TOKEN',
  ]) {
    final value = store.readSync(name) ?? Platform.environment[name];
    if (value != null && value.isNotEmpty) secrets[name] = value;
  }
  return secrets;
}

WorkerTrustPolicy _releaseTrustPolicy(String publisher) {
  final secret = Platform.environment['CONCLAVE_HOST_RELEASE_TRUST_SECRET'];
  return WorkerTrustPolicy(
    trustedSecrets: secret == null ? {} : {publisher: secret},
  );
}

Future<List<int>> downloadWorkerPackage(Uri cloudUri, String? authToken,
    String workerId, String version, String packageR2Key,
    {int maxPackageBytes = 512 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30)}) async {
  if (maxPackageBytes <= 0) {
    throw ArgumentError.value(
        maxPackageBytes, 'maxPackageBytes', 'must be positive');
  }
  final scheme = cloudUri.scheme == 'wss' ? 'https' : 'http';
  final uri = cloudUri.replace(
    scheme: scheme,
    pathSegments: [
      'api',
      'workers',
      workerId,
      'versions',
      version,
      'download',
    ],
    queryParameters: {'packageR2Key': packageR2Key},
  );
  final client = HttpClient();
  try {
    client.connectionTimeout = timeout;
    final request = await client.getUrl(uri).timeout(timeout);
    if (authToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
    }
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'worker download failed with HTTP ${response.statusCode}',
      );
    }
    if (response.contentLength > maxPackageBytes) {
      throw StateError(
          'worker package exceeds the $maxPackageBytes byte package limit');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxPackageBytes) {
        throw StateError(
            'worker package exceeds the $maxPackageBytes byte package limit');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
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
  final workerManager = WorkerManager(
    Directory('${config.dataDirectory.path}/workers'),
    requireSignature: true,
    trustPolicy: workerTrustPolicy,
    allowedPermissions: _configuredPermissions(),
    secretEnvironment: _workerSecrets(),
  );
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
  var activeWorkerIds = (await workerManager.inventory())
      .where((worker) => worker.active)
      .map((worker) => worker.workerId)
      .toSet()
      .toList();
  final repositoryRegistry = await LocalRepositoryRegistry.load(File(
    config.repositoriesFile ?? '${config.dataDirectory.path}/repositories.json',
  ));
  final workerHandler = workerManager.assignmentHandler(
    WorkerProcessExecutor(),
    resolveRepositoryPath: repositoryRegistry.resolve,
    resolveV7Adapter: localWorkerRegistry == null
        ? null
        : (workerId) async {
            final worker = await localWorkerRegistry.find(workerId);
            if (worker == null) return null;
            if (worker.status != LocalWorkerStatus.ready ||
                (worker.authStrategy == 'api_key' &&
                    worker.credentialStatus !=
                        LocalWorkerCredentialStatus.ready)) {
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
    resolvePermissions: localWorkerRegistry == null
        ? null
        : (workerId) async {
            final worker = await localWorkerRegistry.find(workerId);
            if (worker == null) {
              return workerManager.activePermissions(workerId);
            }
            return {
              for (final permission in worker.localPermissions)
                ...switch (permission) {
                  'workstream_filesystem' => {
                      'workspace:read',
                      'workspace:write'
                    },
                  'shell_execution' => {'shell:execute'},
                  'network' => {'network:outbound'},
                  _ => {permission},
                },
            };
          },
    resolveConcurrencyLimit: localWorkerRegistry == null
        ? null
        : (workerId) async {
            final workers = await localWorkerRegistry.list();
            for (final worker in workers) {
              if (worker.id == workerId) return worker.localConcurrencyLimit;
            }
            return null;
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
          syncHandler: (payload) async {
            final raw = payload['desiredWorkers'];
            if (raw is! List) return;
            final desired = raw
                .whereType<Map>()
                .map((item) => Map<String, Object?>.from(item));
            try {
              await workerManager.reconcile(
                desired,
                download: (workerId, version, packageR2Key) =>
                    downloadWorkerPackage(
                  config.cloudUri!,
                  config.authToken,
                  workerId,
                  version,
                  packageR2Key,
                ),
                onStatus: (status) async {
                  final workerId = status['workerId'];
                  final desiredWorker = workerId is String
                      ? desired.firstWhere(
                          (item) => item['workerId'] == workerId,
                          orElse: () => const <String, Object?>{},
                        )
                      : const <String, Object?>{};
                  final packageStatus = status['status'] == 'ready'
                      ? 'ready'
                      : status['status'] == 'failed'
                          ? 'failed'
                          : 'installing';
                  final credentialStatus = desiredWorker['credentialStatus'];
                  final configuredPermissionsStatus =
                      desiredWorker['permissionsStatus'];
                  final permissionsStatus =
                      configuredPermissionsStatus == 'denied'
                          ? 'denied'
                          : status['status'] == 'ready'
                              ? 'ready'
                              : configuredPermissionsStatus;
                  final effectiveReadiness = status['status'] == 'ready' &&
                          credentialStatus == 'ready' &&
                          permissionsStatus == 'ready'
                      ? 'ready'
                      : status['status'] == 'failed'
                          ? 'failed'
                          : 'degraded';
                  connection?.reportWorkerStatuses([
                    {
                      ...status,
                      'packageStatus': packageStatus,
                      if (credentialStatus is String)
                        'credentialStatus': credentialStatus,
                      if (permissionsStatus is String)
                        'permissionsStatus': permissionsStatus,
                      'effectiveReadiness': effectiveReadiness,
                      'activeAssignmentCount': connection.activeAssignmentCount,
                    },
                  ]);
                },
              );
              final inventory = await workerManager.inventory();
              activeWorkerIds = inventory
                  .where((worker) => worker.active)
                  .map((worker) => worker.workerId)
                  .toSet()
                  .toList();
              connection?.reportWorkerStatuses(
                inventory
                    .map((worker) => {
                          'workerId': worker.workerId,
                          'version': worker.version,
                          'status': worker.active ? 'ready' : 'verifying',
                          'packageStatus':
                              worker.active ? 'ready' : 'installing',
                          'effectiveReadiness':
                              worker.active ? 'ready' : 'degraded',
                          'activeAssignmentCount':
                              connection?.activeAssignmentCount ?? 0,
                          'installedAt':
                              DateTime.now().toUtc().toIso8601String(),
                        })
                    .toList(),
              );
            } catch (error) {
              for (final worker in desired) {
                final workerId = worker['workerId'];
                final version = worker['version'];
                if (workerId is! String || version is! String) continue;
                connection?.reportWorkerStatuses([
                  {
                    'workerId': workerId,
                    'version': version,
                    'status': 'failed',
                    'error': '$error',
                    'installedAt': DateTime.now().toUtc().toIso8601String(),
                  },
                ]);
              }
              rethrow;
            }
          },
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
      final workers = await workerManager.inventory();
      return {
        'workers': workers.length,
        'workerIds': workers.map((worker) => worker.workerId).toList(),
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
