import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'first_party_worker_registry.dart';
import 'tool_profile_catalog.dart';
import 'platform_runtime.dart';

const _registrySchemaVersion = 17;

enum LocalWorkerStatus { needsAttention, ready, disabled, removed }

enum LocalWorkerActivationState { enabled, disabled }

enum WorkerReadinessState {
  notProbed('not_probed', 'Not checked'),
  ready('ready', 'Ready'),
  setupRequired('setup_required', 'Setup required'),
  signInRequired('sign_in_required', 'Sign in required'),
  runtimeUnavailable(
      'worker_runtime_unavailable', 'Conclave integration needs attention'),
  testFailed('test_failed', 'Test failed');

  const WorkerReadinessState(this.wireValue, this.label);
  final String wireValue;
  final String label;

  static WorkerReadinessState? parse(Object? value) {
    return WorkerReadinessState.values
        .where((state) => state.wireValue == value)
        .firstOrNull;
  }
}

enum LocalWorkerCredentialStatus {
  notRequired,
  needsAuthentication,
  ready,
  expired,
  error
}

/// Workspace-local state for one fixed product Worker slot.
class LocalConfiguredWorker {
  LocalConfiguredWorker({
    required this.id,
    required this.workspaceId,
    required this.workerTypeId,
    String? name,
    String? authStrategy,
    String? credentialRef,
    String? defaultModel,
    Map<String, Object?> adapterConfig = const {},
    List<String> allowedModels = const [],
    required this.localPermissions,
    required this.localConcurrencyLimit,
    String? adapterVersionPolicy,
    required LocalWorkerStatus status,
    LocalWorkerActivationState? activationState,
    WorkerReadinessState? readinessState,
    LocalWorkerCredentialStatus credentialStatus =
        LocalWorkerCredentialStatus.notRequired,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.lastLiveTestAt,
    this.lastLiveTestPassed,
    this.lastLiveTestDetails,
    this.lastPassiveProbeAt,
    this.readinessIssueCode,
    this.lastLiveTestIssueCode,
    this.toolVersion,
    this.toolName,
    this.toolPath,
  })  : activationState = activationState ??
            (status == LocalWorkerStatus.disabled ||
                    status == LocalWorkerStatus.removed
                ? LocalWorkerActivationState.disabled
                : LocalWorkerActivationState.enabled),
        readinessState = _independentReadiness(
          readinessState,
          workerTypeId: workerTypeId,
          status: status,
          lastLiveTestAt: lastLiveTestAt,
          lastLiveTestPassed: lastLiveTestPassed,
          issueCode: readinessIssueCode ?? lastLiveTestIssueCode,
        );

  final String id;
  final String workspaceId;
  final String workerTypeId;
  final List<String> localPermissions;
  final int localConcurrencyLimit;

  // Read-only compatibility projections for remaining migration-era callers.
  // These values are not held in memory or written to the registry.
  String get name => FirstPartyWorkerPackage.productNameFor(workerTypeId);
  String get authStrategy => 'provider_owned';
  String? get credentialRef => null;
  String? get defaultModel => null;
  Map<String, Object?> get adapterConfig => const {};
  List<String> get allowedModels => const [];
  String? get adapterVersionPolicy => null;
  LocalWorkerCredentialStatus get credentialStatus =>
      LocalWorkerCredentialStatus.notRequired;

  /// Local activation is independent from the package-reported health state.
  final LocalWorkerActivationState activationState;

  /// Compatibility projection for Cloud scheduling. Readiness remains the
  /// local source of truth and activation is independent.
  LocalWorkerStatus get status {
    if (activationState == LocalWorkerActivationState.disabled) {
      return LocalWorkerStatus.disabled;
    }
    if (readinessState == WorkerReadinessState.ready ||
        (readinessState == WorkerReadinessState.setupRequired &&
            lastLiveTestPassed == true)) {
      return LocalWorkerStatus.ready;
    }
    return LocalWorkerStatus.needsAttention;
  }

  final WorkerReadinessState readinessState;
  final int revision;
  final String createdAt;
  final String updatedAt;
  final String? lastLiveTestAt;
  final bool? lastLiveTestPassed;
  final String? lastPassiveProbeAt;
  final String? readinessIssueCode;
  final String? lastLiveTestIssueCode;
  final String? toolVersion;
  final String? toolName;
  final String? toolPath;

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
    LocalWorkerActivationState? activationState,
    WorkerReadinessState? readinessState,
    LocalWorkerCredentialStatus? credentialStatus,
    int? revision,
    String? updatedAt,
    bool clearCredentialRef = false,
    bool clearModelConfiguration = false,
    String? lastLiveTestAt,
    bool? lastLiveTestPassed,
    String? lastLiveTestDetails,
    String? lastPassiveProbeAt,
    String? readinessIssueCode,
    String? lastLiveTestIssueCode,
    String? toolVersion,
    String? toolName,
    bool clearToolName = false,
    String? toolPath,
    bool clearToolPath = false,
    bool clearToolVersion = false,
    bool clearLastLiveTestDetails = false,
    bool clearReadinessIssueCode = false,
    bool clearLastLiveTestIssueCode = false,
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
        activationState: activationState ??
            (status == null
                ? this.activationState
                : status == LocalWorkerStatus.disabled ||
                        status == LocalWorkerStatus.removed
                    ? LocalWorkerActivationState.disabled
                    : LocalWorkerActivationState.enabled),
        readinessState: readinessState ?? this.readinessState,
        credentialStatus: credentialStatus ?? this.credentialStatus,
        revision: revision ?? this.revision,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        lastLiveTestAt: lastLiveTestAt ?? this.lastLiveTestAt,
        lastLiveTestPassed: lastLiveTestPassed ?? this.lastLiveTestPassed,
        lastPassiveProbeAt: lastPassiveProbeAt ?? this.lastPassiveProbeAt,
        readinessIssueCode: clearReadinessIssueCode
            ? null
            : readinessIssueCode ?? this.readinessIssueCode,
        lastLiveTestIssueCode: clearLastLiveTestIssueCode
            ? null
            : lastLiveTestIssueCode ?? this.lastLiveTestIssueCode,
        toolVersion: clearToolVersion ? null : toolVersion ?? this.toolVersion,
        toolName: clearToolName ? null : toolName ?? this.toolName,
        toolPath: clearToolPath ? null : toolPath ?? this.toolPath,
        lastLiveTestDetails: clearLastLiveTestDetails
            ? null
            : lastLiveTestDetails ?? this.lastLiveTestDetails,
      );

  Map<String, Object?> toJson() => {
        'workerId': id,
        'workspaceId': workspaceId,
        'productWorkerTypeId': workerTypeId,
        'localPermissions': localPermissions,
        'localConcurrencyLimit': localConcurrencyLimit,
        'activationState': activationState.name,
        'readinessState': readinessState.wireValue,
        'revision': revision,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'lastLiveTestAt': lastLiveTestAt,
        'lastLiveTestPassed': lastLiveTestPassed,
        'lastLiveTestDetails': lastLiveTestDetails,
        'lastPassiveProbeAt': lastPassiveProbeAt,
        'readinessIssueCode': readinessIssueCode,
        'lastLiveTestIssueCode': lastLiveTestIssueCode,
        'providerToolVersion': toolVersion,
        'providerToolName': toolName,
        'providerToolPath': toolPath,
      };

  factory LocalConfiguredWorker.fromJson(Map<String, dynamic> json) {
    const allowedKeys = {
      'workerId',
      'workspaceId',
      'productWorkerTypeId',
      'localPermissions',
      'localConcurrencyLimit',
      'activationState',
      'readinessState',
      'revision',
      'createdAt',
      'updatedAt',
      'lastLiveTestAt',
      'lastLiveTestPassed',
      'lastLiveTestDetails',
      'lastPassiveProbeAt',
      'readinessIssueCode',
      'lastLiveTestIssueCode',
      'providerToolVersion',
      'providerToolName',
      'providerToolPath',
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

    final lastLiveTestAt = json['lastLiveTestAt'];
    final lastLiveTestPassed = json['lastLiveTestPassed'];
    final lastLiveTestDetails = json['lastLiveTestDetails'];
    final lastPassiveProbeAt = json['lastPassiveProbeAt'];
    final readinessIssueCode = json['readinessIssueCode'];
    final lastLiveTestIssueCode = json['lastLiveTestIssueCode'];
    final toolVersion = json['providerToolVersion'];
    final toolName = json['providerToolName'];
    final toolPath = json['providerToolPath'];
    if (lastLiveTestAt != null && lastLiveTestAt is! String ||
        lastLiveTestPassed != null && lastLiveTestPassed is! bool ||
        lastPassiveProbeAt != null && lastPassiveProbeAt is! String ||
        readinessIssueCode != null && readinessIssueCode is! String ||
        lastLiveTestIssueCode != null && lastLiveTestIssueCode is! String) {
      throw const FormatException(
          'Worker readiness diagnostic fields are invalid');
    }
    if (toolVersion != null &&
        (toolVersion is! String ||
            toolVersion.isEmpty ||
            toolVersion.length > 128)) {
      throw const FormatException('Worker CLI version is invalid');
    }
    if (toolName != null &&
        (toolName is! String ||
            toolName.trim().isEmpty ||
            toolName.length > 128)) {
      throw const FormatException('Worker CLI name is invalid');
    }
    if (toolPath != null &&
        (toolPath is! String ||
            toolPath.length > 4096 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(toolPath) ||
            !RegExp(r'^(?:/|[A-Za-z]:[\\/]|\\\\)').hasMatch(toolPath))) {
      throw const FormatException('Worker CLI path is invalid');
    }
    if (lastLiveTestDetails != null &&
        (lastLiveTestDetails is! String || lastLiveTestDetails.length > 1000)) {
      throw const FormatException('Worker test details are invalid');
    }
    for (final issueCode in [readinessIssueCode, lastLiveTestIssueCode]) {
      if (issueCode != null &&
          (issueCode is! String ||
              !RegExp(r'^[a-z][a-z0-9_]{0,127}$').hasMatch(issueCode))) {
        throw const FormatException('Worker readiness issue code is invalid');
      }
    }
    final activationValue = json['activationState'];
    final activation = LocalWorkerActivationState.values
        .where((item) => item.name == activationValue);
    if (activationValue is! String || activation.isEmpty) {
      throw const FormatException('Worker activation state is invalid');
    }
    final parsedReadinessState =
        WorkerReadinessState.parse(json['readinessState']);
    if (parsedReadinessState == null) {
      throw const FormatException('Worker readiness state is invalid');
    }
    final concurrency = json['localConcurrencyLimit'];
    final revision = json['revision'];
    if (concurrency is! int ||
        concurrency < 1 ||
        revision is! int ||
        revision < 1) {
      throw const FormatException(
          'Worker registry state or revision is invalid');
    }
    final activationState = activation.first;
    final readinessState = parsedReadinessState;
    return LocalConfiguredWorker(
      id: required('workerId'),
      workspaceId: required('workspaceId'),
      name: FirstPartyWorkerPackage.productNameFor(
          required('productWorkerTypeId')),
      workerTypeId: required('productWorkerTypeId'),
      authStrategy: 'provider_owned',
      credentialRef: null,
      defaultModel: null,
      adapterConfig: const {},
      allowedModels: const [],
      localPermissions: strings('localPermissions'),
      localConcurrencyLimit: concurrency,
      adapterVersionPolicy: null,
      status: activationState == LocalWorkerActivationState.disabled
          ? LocalWorkerStatus.disabled
          : readinessState == WorkerReadinessState.ready
              ? LocalWorkerStatus.ready
              : LocalWorkerStatus.needsAttention,
      activationState: activationState,
      readinessState: readinessState,
      credentialStatus: LocalWorkerCredentialStatus.notRequired,
      revision: revision,
      createdAt: required('createdAt'),
      updatedAt: required('updatedAt'),
      lastLiveTestAt: lastLiveTestAt as String?,
      lastLiveTestPassed: lastLiveTestPassed as bool?,
      lastLiveTestDetails: lastLiveTestDetails as String?,
      lastPassiveProbeAt: lastPassiveProbeAt as String?,
      readinessIssueCode: readinessIssueCode as String?,
      lastLiveTestIssueCode: lastLiveTestIssueCode as String?,
      toolVersion: toolVersion as String?,
      toolName: toolName as String?,
      toolPath: toolPath as String?,
    );
  }
}

WorkerReadinessState _independentReadiness(
  WorkerReadinessState? persisted, {
  required String workerTypeId,
  required LocalWorkerStatus status,
  required String? lastLiveTestAt,
  required bool? lastLiveTestPassed,
  required String? issueCode,
}) {
  if (persisted != null) return persisted;
  if (lastLiveTestPassed == true) return WorkerReadinessState.ready;
  if (issueCode == 'cli_not_found') {
    return WorkerReadinessState.runtimeUnavailable;
  }
  if (issueCode == 'setup_required') {
    return WorkerReadinessState.setupRequired;
  }
  if (issueCode == 'authentication_required') {
    return WorkerReadinessState.signInRequired;
  }
  if (workerTypeId == 'gemini' && lastLiveTestAt == null) {
    return WorkerReadinessState.setupRequired;
  }
  if (lastLiveTestPassed == false) return WorkerReadinessState.testFailed;
  return status == LocalWorkerStatus.ready
      ? WorkerReadinessState.ready
      : WorkerReadinessState.testFailed;
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
    this.onLegacyCredentialReference,
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
  final Future<void> Function(String credentialReference)?
      onLegacyCredentialReference;
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
    LogicalWorkerCatalogEntry? approvedCatalogEntry,
  }) =>
      _locked(() async {
        final workers = await _read();
        final normalizedTypeId =
            FirstPartyWorkerPackage.canonicalProductWorkerTypeId(
          workerTypeId.trim(),
        );
        final descriptor = FirstPartyWorkerPackage.forProductWorkerTypeId(
          normalizedTypeId,
        );
        if (descriptor == null &&
            (approvedCatalogEntry == null ||
                approvedCatalogEntry.workerTypeId != normalizedTypeId ||
                approvedCatalogEntry.engineFamily != 'cli')) {
          throw ArgumentError('Worker slot is not in the approved catalog');
        }
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
          name: descriptor?.productName ?? approvedCatalogEntry!.displayName,
          workerTypeId: normalizedTypeId,
          authStrategy: authStrategy,
          credentialRef: credentialRef,
          defaultModel: defaultModel,
          adapterConfig: Map.unmodifiable(adapterConfig),
          allowedModels: List.unmodifiable(allowedModels),
          localPermissions: List.unmodifiable(localPermissions),
          localConcurrencyLimit: localConcurrencyLimit ?? 1,
          adapterVersionPolicy: adapterVersionPolicy,
          status: status,
          readinessState: readinessState,
          credentialStatus: credentialStatus,
          revision: (previous?.revision ?? 0) + 1,
          createdAt: previous?.createdAt ?? now,
          updatedAt: now,
          readinessIssueCode:
              normalizedTypeId == 'gemini' && readinessState == null
                  ? 'setup_required'
                  : null,
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
        final descriptor = FirstPartyWorkerPackage.forProductWorkerTypeId(
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
            FirstPartyWorkerPackage.canonicalProductWorkerTypeId(
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
    await update(
      workerId,
      (current) => current.copyWith(
        status: LocalWorkerStatus.disabled,
        activationState: LocalWorkerActivationState.disabled,
      ),
    );
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
              credentialRef: credentialRef,
            ));
  }

  Future<void> remove(String workerId) => _locked(() async {
        final workers = await _read();
        final index = workers.indexWhere((worker) => worker.id == workerId);
        if (index < 0) return;
        await onWorkerRemoving?.call(workerId);
        workers[index] = workers[index].copyWith(
          status: LocalWorkerStatus.disabled,
          activationState: LocalWorkerActivationState.disabled,
          readinessState: WorkerReadinessState.testFailed,
          readinessIssueCode: 'worker_reconfigured',
          clearToolName: true,
          clearToolPath: true,
          clearToolVersion: true,
          revision: workers[index].revision + 1,
          updatedAt: clock().toUtc().toIso8601String(),
        );
        _validateAll(workers);
        await _write(workers);
      });

  Future<String> exportBackup() => _locked(() async {
        final workers = await _read();
        final body = <String, Object?>{
          'schemaVersion': _registrySchemaVersion,
          'workers': workers.map((worker) => worker.toJson()).toList(),
        };
        return jsonEncode({...body, 'checksum': _checksum(workers)});
      });

  Future<List<LocalConfiguredWorker>> _read() async {
    if (!await file.exists()) return <LocalConfiguredWorker>[];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] is! int ||
          (decoded['schemaVersion'] as int) < 1 ||
          (decoded['schemaVersion'] as int) > _registrySchemaVersion ||
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
      if (schemaVersion < _registrySchemaVersion) {
        final migrated = await _migrateLegacyRegistry(rawWorkers);
        _validateAll(migrated);
        await _write(migrated);
        return migrated;
      }
      var records = rawWorkers.map((item) {
        if (item is! Map) {
          throw const FormatException('Worker record must be an object');
        }
        final json = Map<String, dynamic>.from(item);
        if (schemaVersion == 1) json.remove('ownerUserId');
        return LocalConfiguredWorker.fromJson(json);
      }).toList();
      _validateAll(records);
      return records;
    } on Object catch (error) {
      throw LocalWorkerRegistryCorrupt('cannot read ${file.path}: $error');
    }
  }

  Future<List<LocalConfiguredWorker>> _migrateLegacyRegistry(
    List rawWorkers,
  ) async {
    // Schema 17 deliberately drops adapter-era configuration and readiness
    // state. Preserve only the fixed product slot identity and safe Workspace
    // policy; every slot must be passively probed again after the reset.
    final candidates = <String, List<Map<String, dynamic>>>{};
    final discardedIds = <String>{};
    final legacyCredentialReferences = <String>{};
    for (final raw in rawWorkers) {
      if (raw is! Map) continue;
      final record = Map<String, dynamic>.from(raw);
      final rawId = record['id'] ?? record['workerId'];
      final rawType = record['workerTypeId'] ?? record['productWorkerTypeId'];
      final legacyCredential = record['credentialRef'];
      if (rawId is String && legacyCredential == 'worker-credential/$rawId') {
        legacyCredentialReferences.add(legacyCredential as String);
      }
      if (rawId is! String ||
          rawId.trim().isEmpty ||
          rawType is! String ||
          (record['workspaceId'] is String &&
              record['workspaceId'] != workspaceId)) {
        continue;
      }
      final type = FirstPartyWorkerPackage.canonicalProductWorkerTypeId(
        rawType.trim(),
      );
      if (!{'chatgpt', 'gemini'}.contains(type)) {
        discardedIds.add(rawId);
        continue;
      }
      candidates.putIfAbsent(type, () => []).add(record);
    }

    final migrated = <LocalConfiguredWorker>[];
    final preservedIds = <String>{};
    for (final entry in candidates.entries) {
      // Stable ordering makes duplicate resolution deterministic and keeps the
      // same slot ID on every machine with the same legacy registry.
      entry.value.sort((a, b) =>
          (a['id'] as String? ?? '').compareTo(b['id'] as String? ?? ''));
      final record = entry.value.first;
      final id = (record['id'] ?? record['workerId']) as String;
      preservedIds.add(id);
      final activation = record['activationState'] == 'disabled' ||
              record['status'] == 'disabled' ||
              record['status'] == 'removed'
          ? LocalWorkerActivationState.disabled
          : LocalWorkerActivationState.enabled;
      final permissions = record['localPermissions'];
      final concurrency = record['localConcurrencyLimit'];
      final createdAt = record['createdAt'];
      final revision = record['revision'];
      final now = clock().toUtc().toIso8601String();
      migrated.add(LocalConfiguredWorker(
        id: id,
        workspaceId: workspaceId,
        name: FirstPartyWorkerPackage.productNameFor(entry.key),
        workerTypeId: entry.key,
        authStrategy: 'provider_owned',
        credentialRef: null,
        defaultModel: null,
        adapterConfig: const {},
        allowedModels: const [],
        localPermissions: permissions is List
            ? permissions.whereType<String>().toList()
            : const [],
        localConcurrencyLimit:
            concurrency is int && concurrency > 0 ? concurrency : 1,
        adapterVersionPolicy: null,
        status: LocalWorkerStatus.needsAttention,
        activationState: activation,
        readinessState: WorkerReadinessState.testFailed,
        credentialStatus: LocalWorkerCredentialStatus.notRequired,
        revision: revision is int && revision > 0 ? revision + 1 : 1,
        createdAt: createdAt is String ? createdAt : now,
        updatedAt: now,
        readinessIssueCode: 'worker_reconfigured',
      ));
      for (final duplicate in entry.value.skip(1)) {
        final duplicateId = duplicate['id'] ?? duplicate['workerId'];
        if (duplicateId is String) discardedIds.add(duplicateId);
      }
    }
    discardedIds.removeAll(preservedIds);
    for (final reference in legacyCredentialReferences) {
      await onLegacyCredentialReference?.call(reference);
    }
    for (final oldId in discardedIds) {
      await onWorkerRemoving?.call(oldId);
    }
    migrated.sort((a, b) => a.workerTypeId.compareTo(b.workerTypeId));
    return migrated;
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

  void _validateWorker(LocalConfiguredWorker worker) {
    if (worker.workspaceId != workspaceId ||
        worker.id.trim().isEmpty ||
        !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')
            .hasMatch(worker.workerTypeId) ||
        worker.workerTypeId.length > 96 ||
        worker.localConcurrencyLimit < 1 ||
        worker.revision < 1) {
      throw ArgumentError(
          'Worker registry record violates identity or configuration invariants');
    }
  }

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
}

String _newWorkerId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
