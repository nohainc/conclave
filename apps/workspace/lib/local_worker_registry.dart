import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'tool_profile_catalog.dart';
import 'platform_runtime.dart';

const _registrySchemaVersion = 19;

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

/// Workspace-local state for one configured logical Worker.
class LocalWorker {
  LocalWorker({
    required this.id,
    required this.workspaceId,
    required this.workerTypeId,
    required this.localPermissions,
    required this.localConcurrencyLimit,
    required LocalWorkerStatus status,
    LocalWorkerActivationState? activationState,
    WorkerReadinessState? readinessState,
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
          status: status,
          lastLiveTestPassed: lastLiveTestPassed,
          issueCode: readinessIssueCode ?? lastLiveTestIssueCode,
        );

  final String id;
  final String workspaceId;
  final String workerTypeId;
  final List<String> localPermissions;
  final int localConcurrencyLimit;

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

  LocalWorker copyWith({
    String? workerTypeId,
    List<String>? localPermissions,
    int? localConcurrencyLimit,
    LocalWorkerStatus? status,
    LocalWorkerActivationState? activationState,
    WorkerReadinessState? readinessState,
    int? revision,
    String? updatedAt,
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
      LocalWorker(
        id: id,
        workspaceId: workspaceId,
        workerTypeId: workerTypeId ?? this.workerTypeId,
        localPermissions: localPermissions ?? this.localPermissions,
        localConcurrencyLimit:
            localConcurrencyLimit ?? this.localConcurrencyLimit,
        status: status ?? this.status,
        activationState: activationState ??
            (status == null
                ? this.activationState
                : status == LocalWorkerStatus.disabled ||
                        status == LocalWorkerStatus.removed
                    ? LocalWorkerActivationState.disabled
                    : LocalWorkerActivationState.enabled),
        readinessState: readinessState ?? this.readinessState,
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

  factory LocalWorker.fromJson(Map<String, dynamic> json) {
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
    return LocalWorker(
      id: required('workerId'),
      workspaceId: required('workspaceId'),
      workerTypeId: required('productWorkerTypeId'),
      localPermissions: strings('localPermissions'),
      localConcurrencyLimit: concurrency,
      status: activationState == LocalWorkerActivationState.disabled
          ? LocalWorkerStatus.disabled
          : readinessState == WorkerReadinessState.ready
              ? LocalWorkerStatus.ready
              : LocalWorkerStatus.needsAttention,
      activationState: activationState,
      readinessState: readinessState,
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
  required LocalWorkerStatus status,
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
  if (lastLiveTestPassed == false) return WorkerReadinessState.testFailed;
  return status == LocalWorkerStatus.ready
      ? WorkerReadinessState.ready
      : WorkerReadinessState.notProbed;
}

class LocalWorkerRegistryCorrupt implements Exception {
  const LocalWorkerRegistryCorrupt(this.message);
  final String message;
  @override
  String toString() => 'LocalWorkerRegistryCorrupt: $message';
}

/// Versioned, integrity-checked registry within the Workspace data directory.
/// All mutations are serialized in-process and committed by atomic rename.
class LocalWorkerRegistry {
  LocalWorkerRegistry({
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

  Future<List<LocalWorker>> list({bool includeRemoved = false}) =>
      _locked(() async => (await _read())
          .where((worker) =>
              includeRemoved || worker.status != LocalWorkerStatus.removed)
          .toList());

  Future<LocalWorker?> find(String workerId) => _locked(() async {
        for (final worker in await _read()) {
          if (worker.id == workerId) return worker;
        }
        return null;
      });

  Future<LocalWorker> create({
    required WorkerDescriptor catalogEntry,
    List<String> localPermissions = const [],
    int? localConcurrencyLimit,
    LocalWorkerStatus status = LocalWorkerStatus.needsAttention,
    WorkerReadinessState? readinessState,
  }) =>
      _locked(() async {
        final workers = await _read();
        final normalizedTypeId = catalogEntry.workerTypeId;
        if (catalogEntry.engineFamily != 'cli' ||
            !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')
                .hasMatch(normalizedTypeId)) {
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
        final worker = LocalWorker(
          id: previous?.id ?? idGenerator(),
          workspaceId: workspaceId,
          workerTypeId: normalizedTypeId,
          localPermissions: List.unmodifiable(localPermissions),
          localConcurrencyLimit: localConcurrencyLimit ?? 1,
          status: status,
          readinessState: readinessState,
          revision: (previous?.revision ?? 0) + 1,
          createdAt: previous?.createdAt ?? now,
          updatedAt: now,
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

  Future<LocalWorker> update(
    String workerId,
    LocalWorker Function(LocalWorker current) change,
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
        final updated = proposed.copyWith(
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

  Future<List<LocalWorker>> _read() async {
    if (!await file.exists()) return <LocalWorker>[];
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
      if (schemaVersion < _registrySchemaVersion) {
        // This development reset intentionally does not migrate old slot
        // records, package IDs, permissions, or provider configuration.
        await _write(const []);
        return <LocalWorker>[];
      }
      final expected = _checksumRaw(schemaVersion, rawWorkers);
      if (decoded['checksum'] != expected) {
        throw const FormatException('checksum mismatch');
      }
      final records = rawWorkers.map((item) {
        if (item is! Map) {
          throw const FormatException('Worker record must be an object');
        }
        final json = Map<String, dynamic>.from(item);
        return LocalWorker.fromJson(json);
      }).toList();
      _validateAll(records);
      return records;
    } on Object catch (error) {
      throw LocalWorkerRegistryCorrupt('cannot read ${file.path}: $error');
    }
  }

  Future<void> _write(List<LocalWorker> workers) async {
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

  void _validateAll(List<LocalWorker> workers) {
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

  void _validateWorker(LocalWorker worker) {
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

  void _validateTypeUnique(List<LocalWorker> workers, LocalWorker candidate,
      {String? excludingId}) {
    if (workers.any((worker) =>
        worker.id != excludingId &&
        worker.workerTypeId == candidate.workerTypeId)) {
      throw ArgumentError(
          'A Workspace can have only one record per Worker Type');
    }
  }

  String _checksum(List<LocalWorker> workers) {
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
