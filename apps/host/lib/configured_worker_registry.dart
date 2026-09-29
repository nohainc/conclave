import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'first_party_worker_adapter_descriptor.dart';
import 'platform_runtime.dart';

const _registrySchemaVersion = 11;

enum LocalWorkerStatus { needsAttention, ready, disabled, removed }

enum WorkerReadinessState {
  ready('ready', 'Ready'),
  notInstalled('not_installed', 'Not installed'),
  signInRequired('sign_in_required', 'Sign in required'),
  unsupportedCliVersion('unsupported_cli_version', 'Unsupported CLI version'),
  adapterUnavailable(
      'adapter_unavailable', 'Conclave integration needs attention'),
  disabled('disabled', 'Disabled'),
  testFailed('test_failed', 'Test failed');

  const WorkerReadinessState(this.wireValue, this.label);
  final String wireValue;
  final String label;

  static WorkerReadinessState? parse(Object? value) =>
      WorkerReadinessState.values
          .where((state) => state.wireValue == value)
          .firstOrNull;
}

enum LocalWorkerCredentialStatus {
  notRequired,
  needsAuthentication,
  ready,
  expired,
  error
}

/// Workspace-owned configuration for a single executable Worker identity.
/// Credential material is never represented here. credentialRef is only an
/// opaque key into the platform secure store for locally supplied credentials.
/// Provider-owned CLI sessions (such as Codex) are checked in that provider's
/// local auth store and do not use a Conclave credential reference.
class LocalConfiguredWorker {
  const LocalConfiguredWorker({
    required this.id,
    required this.workspaceId,
    required this.name,
    required this.workerTypeId,
    required this.authStrategy,
    required this.credentialRef,
    required this.defaultModel,
    required this.adapterConfig,
    required this.allowedModels,
    required this.localPermissions,
    required this.localConcurrencyLimit,
    required this.adapterVersionPolicy,
    required LocalWorkerStatus status,
    WorkerReadinessState? readinessState,
    required this.credentialStatus,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.executablePath,
    this.cliVersion,
    this.lastLiveTestAt,
    this.lastLiveTestPassed,
    this.lastLiveTestDetails,
  })  : status = status,
        readinessState = readinessState ??
            (status == LocalWorkerStatus.ready
                ? WorkerReadinessState.ready
                : status == LocalWorkerStatus.disabled ||
                        status == LocalWorkerStatus.removed
                    ? WorkerReadinessState.disabled
                    : WorkerReadinessState.testFailed);

  final String id;
  final String workspaceId;
  final String name;
  final String workerTypeId;
  final String authStrategy;
  final String? credentialRef;
  final String? defaultModel;
  final Map<String, Object?> adapterConfig;
  final List<String> allowedModels;
  final List<String> localPermissions;
  final int localConcurrencyLimit;
  final String? adapterVersionPolicy;
  final LocalWorkerStatus status;
  final WorkerReadinessState readinessState;
  final LocalWorkerCredentialStatus credentialStatus;
  final int revision;
  final String createdAt;
  final String updatedAt;
  final String? executablePath;
  final String? cliVersion;
  final String? lastLiveTestAt;
  final bool? lastLiveTestPassed;

  /// Bounded, provider-neutral local diagnostic. Raw CLI output is never kept.
  final String? lastLiveTestDetails;

  LocalConfiguredWorker copyWith({
    String? name,
    String? workerTypeId,
    String? authStrategy,
    String? credentialRef,
    String? defaultModel,
    Map<String, Object?>? adapterConfig,
    List<String>? allowedModels,
    List<String>? localPermissions,
    int? localConcurrencyLimit,
    String? adapterVersionPolicy,
    LocalWorkerStatus? status,
    WorkerReadinessState? readinessState,
    LocalWorkerCredentialStatus? credentialStatus,
    int? revision,
    String? updatedAt,
    bool clearCredentialRef = false,
    bool clearModelConfiguration = false,
    String? executablePath,
    String? cliVersion,
    String? lastLiveTestAt,
    bool? lastLiveTestPassed,
    String? lastLiveTestDetails,
    bool clearExecutable = false,
    bool clearLastLiveTestDetails = false,
  }) =>
      LocalConfiguredWorker(
        id: id,
        workspaceId: workspaceId,
        name: name ?? this.name,
        workerTypeId: workerTypeId ?? this.workerTypeId,
        authStrategy: authStrategy ?? this.authStrategy,
        credentialRef:
            clearCredentialRef ? null : credentialRef ?? this.credentialRef,
        defaultModel:
            clearModelConfiguration ? null : defaultModel ?? this.defaultModel,
        adapterConfig: adapterConfig ?? this.adapterConfig,
        allowedModels: clearModelConfiguration
            ? const []
            : allowedModels ?? this.allowedModels,
        localPermissions: localPermissions ?? this.localPermissions,
        localConcurrencyLimit:
            localConcurrencyLimit ?? this.localConcurrencyLimit,
        adapterVersionPolicy: adapterVersionPolicy ?? this.adapterVersionPolicy,
        status: status ?? this.status,
        readinessState: readinessState ?? this.readinessState,
        credentialStatus: credentialStatus ?? this.credentialStatus,
        revision: revision ?? this.revision,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        executablePath:
            clearExecutable ? null : executablePath ?? this.executablePath,
        cliVersion: clearExecutable ? null : cliVersion ?? this.cliVersion,
        lastLiveTestAt: lastLiveTestAt ?? this.lastLiveTestAt,
        lastLiveTestPassed: lastLiveTestPassed ?? this.lastLiveTestPassed,
        lastLiveTestDetails: clearLastLiveTestDetails
            ? null
            : lastLiveTestDetails ?? this.lastLiveTestDetails,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'workspaceId': workspaceId,
        'name': name,
        'workerTypeId': workerTypeId,
        'authStrategy': authStrategy,
        'credentialRef': credentialRef,
        'defaultModel': defaultModel,
        'adapterConfig': adapterConfig,
        'allowedModels': allowedModels,
        'localPermissions': localPermissions,
        'localConcurrencyLimit': localConcurrencyLimit,
        'adapterVersionPolicy': adapterVersionPolicy,
        'status': status.name,
        'readinessState': readinessState.wireValue,
        'credentialStatus': credentialStatus.name,
        'revision': revision,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'executablePath': executablePath,
        'cliVersion': cliVersion,
        'lastLiveTestAt': lastLiveTestAt,
        'lastLiveTestPassed': lastLiveTestPassed,
        'lastLiveTestDetails': lastLiveTestDetails,
      };

  factory LocalConfiguredWorker.fromJson(Map<String, dynamic> json) {
    const allowedKeys = {
      'id',
      'workspaceId',
      'name',
      'workerTypeId',
      'authStrategy',
      'credentialRef',
      'defaultModel',
      'adapterConfig',
      'allowedModels',
      'localPermissions',
      'localConcurrencyLimit',
      'adapterVersionPolicy',
      'status',
      'readinessState',
      'credentialStatus',
      'revision',
      'createdAt',
      'updatedAt',
      'executablePath',
      'cliVersion',
      'lastLiveTestAt',
      'lastLiveTestPassed',
      'lastLiveTestDetails',
    };
    if (json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException(
          'Worker registry contains an unsupported field');
    }
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Worker registry field $key is required');
      }
      return value;
    }

    List<String> strings(String key) {
      final value = json[key];
      if (value is! List || value.any((item) => item is! String)) {
        throw FormatException(
            'Worker registry field $key must be a string list');
      }
      return value.cast<String>();
    }

    final credentialRef = json['credentialRef'];
    final defaultModel = json['defaultModel'];
    final adapterConfig = json['adapterConfig'];
    final adapterVersionPolicy = json['adapterVersionPolicy'];
    final executablePath = json['executablePath'];
    final cliVersion = json['cliVersion'];
    final lastLiveTestAt = json['lastLiveTestAt'];
    final lastLiveTestPassed = json['lastLiveTestPassed'];
    final lastLiveTestDetails = json['lastLiveTestDetails'];
    if (credentialRef != null && credentialRef is! String ||
        defaultModel != null && defaultModel is! String ||
        adapterVersionPolicy != null && adapterVersionPolicy is! String) {
      throw const FormatException(
          'Worker registry optional text fields are invalid');
    }
    if (executablePath != null && executablePath is! String ||
        cliVersion != null && cliVersion is! String ||
        lastLiveTestAt != null && lastLiveTestAt is! String ||
        lastLiveTestPassed != null && lastLiveTestPassed is! bool) {
      throw const FormatException(
          'Worker readiness diagnostic fields are invalid');
    }
    if (lastLiveTestDetails != null &&
        (lastLiveTestDetails is! String || lastLiveTestDetails.length > 1000)) {
      throw const FormatException('Worker test details are invalid');
    }
    if (adapterConfig != null && adapterConfig is! Map) {
      throw const FormatException(
          'Worker registry adapterConfig must be an object');
    }
    final status =
        LocalWorkerStatus.values.where((item) => item.name == json['status']);
    final credentialStatus = LocalWorkerCredentialStatus.values
        .where((item) => item.name == json['credentialStatus']);
    final parsedReadinessState =
        WorkerReadinessState.parse(json['readinessState']);
    if (json['readinessState'] != null && parsedReadinessState == null) {
      throw const FormatException('Worker readiness state is invalid');
    }
    final readinessState = parsedReadinessState ??
        (json['status'] == LocalWorkerStatus.ready.name
            ? WorkerReadinessState.ready
            : json['status'] == LocalWorkerStatus.disabled.name ||
                    json['status'] == LocalWorkerStatus.removed.name
                ? WorkerReadinessState.disabled
                : WorkerReadinessState.testFailed);
    final concurrency = json['localConcurrencyLimit'];
    final revision = json['revision'];
    if (status.isEmpty ||
        credentialStatus.isEmpty ||
        concurrency is! int ||
        concurrency < 1 ||
        revision is! int ||
        revision < 1) {
      throw const FormatException(
          'Worker registry state or revision is invalid');
    }
    return LocalConfiguredWorker(
      id: required('id'),
      workspaceId: required('workspaceId'),
      name: required('name'),
      workerTypeId: required('workerTypeId'),
      authStrategy: required('authStrategy'),
      credentialRef: credentialRef as String?,
      defaultModel: defaultModel as String?,
      adapterConfig: adapterConfig == null
          ? const {}
          : Map<String, Object?>.from(adapterConfig as Map),
      allowedModels: strings('allowedModels'),
      localPermissions: strings('localPermissions'),
      localConcurrencyLimit: concurrency,
      adapterVersionPolicy: adapterVersionPolicy as String?,
      status: status.first,
      readinessState: readinessState,
      credentialStatus: credentialStatus.first,
      revision: revision,
      createdAt: required('createdAt'),
      updatedAt: required('updatedAt'),
      executablePath: executablePath as String?,
      cliVersion: cliVersion as String?,
      lastLiveTestAt: lastLiveTestAt as String?,
      lastLiveTestPassed: lastLiveTestPassed as bool?,
      lastLiveTestDetails: lastLiveTestDetails as String?,
    );
  }
}

class LocalWorkerRegistryCorrupt implements Exception {
  const LocalWorkerRegistryCorrupt(this.message);
  final String message;
  @override
  String toString() => 'LocalWorkerRegistryCorrupt: $message';
}

/// Versioned, integrity-checked registry within the Workspace data directory.
/// All mutations are serialized in-process and committed by atomic rename.
class LocalConfiguredWorkerRegistry {
  LocalConfiguredWorkerRegistry({
    required this.dataDirectory,
    required this.workspaceId,
    PlatformRuntime? platform,
    DateTime Function()? clock,
    String Function()? idGenerator,
    this.onWorkerRemoving,
    this.onChanged,
  })  : platform = platform ?? currentPlatformRuntime,
        clock = clock ?? DateTime.now,
        idGenerator = idGenerator ?? _newWorkerId {
    if (workspaceId.trim().isEmpty) {
      throw ArgumentError(
          'Workspace ID is required for the local Worker registry');
    }
  }

  final Directory dataDirectory;
  final String workspaceId;
  final PlatformRuntime platform;
  final DateTime Function() clock;
  final String Function() idGenerator;
  final Future<void> Function(String workerId)? onWorkerRemoving;
  final FutureOr<void> Function()? onChanged;
  Future<void> _tail = Future<void>.value();

  File get file => File(
      '${dataDirectory.path}${Platform.pathSeparator}configured-workers.json');

  Future<T> _locked<T>(Future<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<List<LocalConfiguredWorker>> list({bool includeRemoved = false}) =>
      _locked(() async => (await _read())
          .where((worker) =>
              includeRemoved || worker.status != LocalWorkerStatus.removed)
          .toList());

  Future<LocalConfiguredWorker?> find(String workerId) => _locked(() async {
        for (final worker in await _read()) {
          if (worker.id == workerId) return worker;
        }
        return null;
      });

  Future<LocalConfiguredWorker> create({
    required String name,
    required String workerTypeId,
    required String authStrategy,
    String? credentialRef,
    String? defaultModel,
    Map<String, Object?> adapterConfig = const {},
    List<String> allowedModels = const [],
    List<String> localPermissions = const [],
    int? localConcurrencyLimit,
    String? adapterVersionPolicy,
    LocalWorkerStatus status = LocalWorkerStatus.needsAttention,
    WorkerReadinessState? readinessState,
    LocalWorkerCredentialStatus credentialStatus =
        LocalWorkerCredentialStatus.needsAuthentication,
    String? executablePath,
    String? cliVersion,
  }) =>
      _locked(() async {
        final workers = await _read();
        if (workers
                .where((worker) => worker.status != LocalWorkerStatus.removed)
                .length >=
            500) {
          throw StateError('A Workspace can sync at most 500 Workers.');
        }
        final normalizedTypeId =
            FirstPartyWorkerAdapterDescriptor.canonicalProductWorkerTypeId(
          workerTypeId.trim(),
        );
        final descriptor =
            FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId(
          normalizedTypeId,
        );
        final existingSlot = workers
            .indexWhere((worker) => worker.workerTypeId == normalizedTypeId);
        final now = clock().toUtc().toIso8601String();
        if (existingSlot >= 0 &&
            workers[existingSlot].status != LocalWorkerStatus.removed) {
          throw ArgumentError(
              'This Worker Type is already configured in this Workspace');
        }
        final previous = existingSlot < 0 ? null : workers[existingSlot];
        final worker = LocalConfiguredWorker(
          id: previous?.id ?? idGenerator(),
          workspaceId: workspaceId,
          name: descriptor?.productName ?? name.trim(),
          workerTypeId: normalizedTypeId,
          authStrategy: authStrategy,
          credentialRef: credentialRef,
          defaultModel: defaultModel,
          adapterConfig: Map.unmodifiable(adapterConfig),
          allowedModels: List.unmodifiable(allowedModels),
          localPermissions: List.unmodifiable(localPermissions),
          localConcurrencyLimit:
              localConcurrencyLimit ?? descriptor?.defaultLocalConcurrency ?? 1,
          adapterVersionPolicy: adapterVersionPolicy,
          status: status,
          readinessState: status == LocalWorkerStatus.disabled
              ? WorkerReadinessState.disabled
              : readinessState ??
                  (status == LocalWorkerStatus.ready
                      ? WorkerReadinessState.ready
                      : WorkerReadinessState.testFailed),
          credentialStatus: credentialStatus,
          revision: (previous?.revision ?? 0) + 1,
          createdAt: previous?.createdAt ?? now,
          updatedAt: now,
          executablePath: executablePath ?? previous?.executablePath,
          cliVersion: cliVersion ?? previous?.cliVersion,
        );
        if (previous == null &&
            workers.any((existing) => existing.id == worker.id)) {
          throw StateError('Worker ID generator returned a duplicate ID');
        }
        _validateWorker(worker);
        _validateTypeUnique(workers, worker, excludingId: previous?.id);
        if (previous == null) {
          await _write([...workers, worker]);
        } else {
          workers[existingSlot] = worker;
          await _write(workers);
        }
        return worker;
      });

  Future<LocalConfiguredWorker> update(
    String workerId,
    LocalConfiguredWorker Function(LocalConfiguredWorker current) change,
  ) =>
      _locked(() async {
        final workers = await _read();
        final index = workers.indexWhere((worker) => worker.id == workerId);
        if (index < 0) throw StateError('Worker does not exist');
        final current = workers[index];
        if (current.status == LocalWorkerStatus.removed) {
          throw StateError('Removed Worker records cannot be edited');
        }
        final proposed = change(current);
        final descriptor =
            FirstPartyWorkerAdapterDescriptor.forProductWorkerTypeId(
          current.workerTypeId,
        );
        final updated = proposed.copyWith(
          name: descriptor?.productName ?? proposed.name,
          revision: current.revision + 1,
          updatedAt: clock().toUtc().toIso8601String(),
        );
        if (updated.id != current.id ||
            updated.workspaceId != workspaceId ||
            updated.createdAt != current.createdAt) {
          throw StateError(
              'Worker identity and ownership fields are immutable');
        }
        _validateWorker(updated);
        if (updated.workerTypeId !=
            FirstPartyWorkerAdapterDescriptor.canonicalProductWorkerTypeId(
              updated.workerTypeId,
            )) {
          throw ArgumentError('Worker Type ID is not canonical');
        }
        _validateTypeUnique(workers, updated, excludingId: workerId);
        workers[index] = updated;
        await _write(workers);
        return updated;
      });

  Future<void> disable(String workerId) async {
    await update(workerId,
        (current) => current.copyWith(status: LocalWorkerStatus.disabled));
  }

  Future<void> setCredentialState(
    String workerId,
    LocalWorkerCredentialStatus status, {
    String? credentialRef,
  }) async {
    await update(
        workerId,
        (current) => current.copyWith(
              credentialStatus: status,
              status: status == LocalWorkerCredentialStatus.ready
                  ? LocalWorkerStatus.ready
                  : LocalWorkerStatus.needsAttention,
              credentialRef: credentialRef,
            ));
  }

  Future<void> remove(String workerId) => _locked(() async {
        final workers = await _read();
        final index = workers.indexWhere((worker) => worker.id == workerId);
        if (index < 0 || workers[index].status == LocalWorkerStatus.removed) {
          return;
        }
        await onWorkerRemoving?.call(workerId);
        workers[index] = workers[index].copyWith(
          status: LocalWorkerStatus.removed,
          credentialStatus: const {'none', 'local_endpoint'}
                  .contains(workers[index].authStrategy)
              ? LocalWorkerCredentialStatus.notRequired
              : LocalWorkerCredentialStatus.needsAuthentication,
          clearCredentialRef: true,
          revision: workers[index].revision + 1,
          updatedAt: clock().toUtc().toIso8601String(),
        );
        _validateAll(workers);
        await _write(workers);
      });

  /// Backup omits local secure-store references; restored Workers require local
  /// credential setup before becoming Ready.
  Future<String> exportBackup() => _locked(() async {
        final workers = (await _read())
            .where((worker) => worker.status != LocalWorkerStatus.removed)
            .map((worker) => {
                  ...worker.toJson(),
                  'credentialRef': null,
                  'credentialStatus': worker.credentialStatus ==
                          LocalWorkerCredentialStatus.notRequired
                      ? LocalWorkerCredentialStatus.notRequired.name
                      : LocalWorkerCredentialStatus.needsAuthentication.name,
                  'status': worker.status == LocalWorkerStatus.disabled
                      ? LocalWorkerStatus.disabled.name
                      : LocalWorkerStatus.needsAttention.name,
                })
            .toList();
        return jsonEncode(
            {'schemaVersion': _registrySchemaVersion, 'workers': workers});
      });

  Future<List<LocalConfiguredWorker>> _read() async {
    if (!await file.exists()) return <LocalConfiguredWorker>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          (decoded['schemaVersion'] != 1 &&
              decoded['schemaVersion'] != 2 &&
              decoded['schemaVersion'] != 3 &&
              decoded['schemaVersion'] != 4 &&
              decoded['schemaVersion'] != 5 &&
              decoded['schemaVersion'] != 6 &&
              decoded['schemaVersion'] != 7 &&
              decoded['schemaVersion'] != 8 &&
              decoded['schemaVersion'] != 9 &&
              decoded['schemaVersion'] != 10 &&
              decoded['schemaVersion'] != _registrySchemaVersion) ||
          decoded['workers'] is! List ||
          decoded['checksum'] is! String) {
        throw const FormatException(
            'unsupported or incomplete registry document');
      }
      final schemaVersion = decoded['schemaVersion'] as int;
      final rawWorkers = decoded['workers'] as List;
      final expected = _checksumRaw(schemaVersion, rawWorkers);
      if (decoded['checksum'] != expected) {
        throw const FormatException('checksum mismatch');
      }
      var records = rawWorkers.map((item) {
        if (item is! Map) {
          throw const FormatException('Worker record must be an object');
        }
        final json = Map<String, dynamic>.from(item);
        if (schemaVersion == 1) json.remove('ownerUserId');
        return LocalConfiguredWorker.fromJson(json);
      }).toList();
      if (schemaVersion < _registrySchemaVersion) {
        _validateLegacyRecords(records);
        final migrated = _migrateRecords(
          records,
          clearModelConfiguration: schemaVersion < 7,
        );
        final keptIds = migrated.map((worker) => worker.id).toSet();
        for (final duplicate in records.where((worker) =>
            !keptIds.contains(worker.id) &&
            worker.status != LocalWorkerStatus.removed)) {
          await onWorkerRemoving?.call(duplicate.id);
        }
        records = migrated;
        _validateAll(records);
        await _write(records);
      } else {
        _validateAll(records);
      }
      return records;
    } on Object catch (error) {
      throw LocalWorkerRegistryCorrupt('cannot read ${file.path}: $error');
    }
  }

  Future<void> _write(List<LocalConfiguredWorker> workers) async {
    await dataDirectory.create(recursive: true);
    await platform.restrictPermissions(dataDirectory.path, directory: true);
    final body = <String, Object?>{
      'schemaVersion': _registrySchemaVersion,
      'workers': workers.map((worker) => worker.toJson()).toList(),
    };
    final document = {...body, 'checksum': _checksum(workers)};
    final temporary = File('${file.path}.tmp-$pid-${idGenerator()}');
    try {
      await temporary.writeAsString(jsonEncode(document), flush: true);
      await platform.restrictPermissions(temporary.path, directory: false);
      await temporary.rename(file.path);
      final changed = onChanged;
      if (changed != null) {
        // Notify after the registry's mutation lock is released; inventory
        // providers read this registry to build their Cloud snapshot.
        unawaited(Future<void>.delayed(Duration.zero)
            .then((_) => changed())
            .catchError((Object _) {}));
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  void _validateAll(List<LocalConfiguredWorker> workers) {
    final ids = <String>{};
    final types = <String>{};
    for (final worker in workers) {
      _validateWorker(worker);
      if (!ids.add(worker.id)) {
        throw const FormatException('duplicate Worker ID');
      }
      if (!types.add(worker.workerTypeId)) {
        throw const FormatException('duplicate Workspace Worker Type');
      }
    }
  }

  void _validateLegacyRecords(List<LocalConfiguredWorker> workers) {
    final ids = <String>{};
    for (final worker in workers) {
      _validateWorker(worker);
      if (!ids.add(worker.id)) {
        throw const FormatException('duplicate Worker ID');
      }
    }
  }

  void _validateWorker(LocalConfiguredWorker worker) {
    if (worker.workspaceId != workspaceId ||
        worker.id.trim().isEmpty ||
        worker.name.trim().isEmpty ||
        worker.workerTypeId.trim().isEmpty ||
        worker.authStrategy.trim().isEmpty ||
        worker.localConcurrencyLimit < 1 ||
        worker.revision < 1) {
      throw ArgumentError(
          'Worker registry record violates identity or configuration invariants');
    }
    if (worker.executablePath != null &&
        !_isAbsoluteExecutablePath(worker.executablePath!)) {
      throw ArgumentError('executablePath must be an absolute path');
    }
    if (worker.cliVersion != null &&
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(worker.cliVersion!)) {
      throw ArgumentError('cliVersion must be a detected semantic version');
    }
    if ((worker.executablePath == null) != (worker.cliVersion == null)) {
      throw ArgumentError(
          'executablePath and cliVersion must be stored together');
    }
    if (worker.credentialRef != null &&
        worker.credentialRef != 'worker-credential/${worker.id}') {
      throw ArgumentError(
          'credentialRef must refer to this Worker secure-store key');
    }
    if (worker.status == LocalWorkerStatus.removed &&
        worker.credentialRef != null) {
      throw ArgumentError(
          'removed Worker must not retain a credential reference');
    }
    final configJson = jsonEncode(worker.adapterConfig);
    if (configJson.length > 65536 || _containsSecretKey(worker.adapterConfig)) {
      throw ArgumentError(
          'adapterConfig must be small and contain no secret fields');
    }
    final endpointUrl = worker.adapterConfig['endpointUrl'];
    if (endpointUrl != null) {
      if (endpointUrl is! String) {
        throw ArgumentError('endpointUrl must be a string');
      }
      final endpoint = Uri.tryParse(endpointUrl);
      final sensitiveQueryKey = RegExp(
        r'(secret|token|password|api[_-]?key|authorization)',
        caseSensitive: false,
      );
      if (endpoint == null ||
          !const {'http', 'https'}.contains(endpoint.scheme) ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.queryParameters.keys.any(sensitiveQueryKey.hasMatch)) {
        throw ArgumentError(
            'endpointUrl must not contain embedded credentials');
      }
    }
    if (worker.authStrategy == 'none' &&
        worker.credentialStatus != LocalWorkerCredentialStatus.notRequired) {
      throw ArgumentError(
          'no-auth Worker must not require credential readiness');
    }
    if (worker.credentialStatus == LocalWorkerCredentialStatus.ready &&
        worker.authStrategy == 'api_key' &&
        (worker.credentialRef == null || worker.credentialRef!.isEmpty)) {
      throw ArgumentError(
          'ready API-key Worker requires a secure credential reference');
    }
  }

  bool _isAbsoluteExecutablePath(String path) => Platform.isWindows
      ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
      : path.startsWith('/');

  void _validateTypeUnique(
      List<LocalConfiguredWorker> workers, LocalConfiguredWorker candidate,
      {String? excludingId}) {
    if (workers.any((worker) =>
        worker.id != excludingId &&
        worker.workerTypeId == candidate.workerTypeId)) {
      throw ArgumentError(
          'A Workspace can have only one record per Worker Type');
    }
  }

  List<LocalConfiguredWorker> _migrateRecords(
    List<LocalConfiguredWorker> records, {
    required bool clearModelConfiguration,
  }) {
    final normalized = records.map((worker) {
      final canonicalType =
          FirstPartyWorkerAdapterDescriptor.canonicalProductWorkerTypeId(
        worker.workerTypeId,
      );
      return worker.copyWith(
        workerTypeId: canonicalType,
        name: FirstPartyWorkerAdapterDescriptor.productNameFor(canonicalType),
        // Cloud rejects stale adapter package IDs. Advancing the revision
        // ensures its inventory upsert accepts the canonical product ID.
        revision: canonicalType == worker.workerTypeId
            ? worker.revision
            : worker.revision + 1,
        clearModelConfiguration: clearModelConfiguration,
      );
    }).toList();

    final groups = <String, List<LocalConfiguredWorker>>{};
    for (final worker in normalized) {
      groups.putIfAbsent(worker.workerTypeId, () => []).add(worker);
    }
    final migrated = <LocalConfiguredWorker>[];
    for (final group in groups.values) {
      group.sort(_migrationPreference);
      migrated.add(group.first);
    }
    migrated.sort((a, b) {
      final byType = a.workerTypeId.compareTo(b.workerTypeId);
      return byType != 0 ? byType : a.id.compareTo(b.id);
    });
    return migrated;
  }

  int _migrationPreference(LocalConfiguredWorker a, LocalConfiguredWorker b) {
    int score(LocalConfiguredWorker worker) {
      var value = switch (worker.status) {
        LocalWorkerStatus.ready => 40,
        LocalWorkerStatus.disabled => 30,
        LocalWorkerStatus.needsAttention => 20,
        LocalWorkerStatus.removed => 0,
      };
      if (worker.credentialStatus == LocalWorkerCredentialStatus.ready) {
        value += 8;
      }
      if (worker.credentialRef != null) value += 4;
      if (worker.defaultModel != null) value += 2;
      if (worker.adapterConfig.isNotEmpty ||
          worker.allowedModels.isNotEmpty ||
          worker.localPermissions.isNotEmpty) {
        value += 1;
      }
      return value;
    }

    final byConfiguration = score(b).compareTo(score(a));
    if (byConfiguration != 0) return byConfiguration;
    final byCreation = a.createdAt.compareTo(b.createdAt);
    return byCreation != 0 ? byCreation : a.id.compareTo(b.id);
  }

  String _checksum(List<LocalConfiguredWorker> workers) {
    return _checksumRaw(
      _registrySchemaVersion,
      workers.map((worker) => worker.toJson()).toList(),
    );
  }

  String _checksumRaw(int schemaVersion, Object workers) {
    final canonical =
        jsonEncode({'schemaVersion': schemaVersion, 'workers': workers});
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  bool _containsSecretKey(Map<String, Object?> value) {
    final sensitive = RegExp(
      r'(secret|token|password|api[_-]?key|cookie|authorization|private[_-]?key)',
      caseSensitive: false,
    );
    for (final entry in value.entries) {
      if (sensitive.hasMatch(entry.key)) return true;
      final nested = entry.value;
      if (nested is Map &&
          _containsSecretKey(Map<String, Object?>.from(nested))) {
        return true;
      }
      if (nested is List &&
          nested.any((item) =>
              item is Map &&
              _containsSecretKey(Map<String, Object?>.from(item)))) {
        return true;
      }
    }
    return false;
  }
}

String _newWorkerId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
