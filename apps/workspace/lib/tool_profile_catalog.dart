import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conclave_protocol/worker_descriptor.dart';

export 'package:conclave_protocol/worker_descriptor.dart';

import 'self_update.dart';
import 'tool_profile_release_store.dart';
import 'tool_profile_release_verifier.dart';
import 'worker_trust_policy.dart';

typedef ToolProfileListLoader = Future<ToolProfileCatalogResult> Function(
  String workerTypeId,
  String defaultChannel,
);
typedef WorkerDescriptorLoader = Future<List<Object?>> Function();

class ToolProfileCatalogResult {
  const ToolProfileCatalogResult({
    required this.channel,
    required this.releases,
  });

  final String channel;
  final List<Object?> releases;
}

typedef ToolProfileTrustRefresher = Future<void> Function();
typedef ToolProfileCandidateValidator = Future<bool> Function(
  ToolProfileReleaseAdmission candidate,
  File profileFile,
);
typedef ToolProfileRevocationHandler = Future<void> Function(
  Set<String> affectedWorkerTypeIds,
);

/// Downloads the Workspace's Cloud-selected official channel and activates a
/// candidate only after its passive probe succeeds.
class ToolProfileCatalogClient {
  ToolProfileCatalogClient({
    required this.cloudUri,
    required this.store,
    required this.trustPolicy,
    this.workspaceRuntimeId,
    this.authToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
    this.listLoader,
    this.workerCatalogLoader,
    this.trustRefresher,
    this.candidateValidator,
    this.onRevocationsApplied,
  }) : _client = client ?? HttpClient();

  static const maxResponseBytes = 2 * 1024 * 1024;
  static const maxProfilesPerResponse = 64;
  static const maxWorkersPerResponse = 64;

  final Uri cloudUri;
  final ToolProfileReleaseStore store;
  final WorkerTrustPolicy trustPolicy;
  final String? workspaceRuntimeId;
  final String? authToken;
  final Duration timeout;
  final ToolProfileListLoader? listLoader;
  final WorkerDescriptorLoader? workerCatalogLoader;
  final ToolProfileTrustRefresher? trustRefresher;
  final ToolProfileCandidateValidator? candidateValidator;
  final ToolProfileRevocationHandler? onRevocationsApplied;
  final HttpClient _client;
  List<WorkerDescriptor> _workers = const [];
  bool _catalogPersisted = false;
  List<WorkerDescriptor> get workers => _workers;

  WorkerDescriptor? entryForWorker(String workerTypeId) =>
      _workers.where((entry) => entry.workerTypeId == workerTypeId).firstOrNull;

  String? profileDefinitionForWorker(String workerTypeId) =>
      entryForWorker(workerTypeId)?.profileDefinitionId;

  /// Fetches the approved, Cloud-selected catalog; a bounded local snapshot is
  /// retained for offline rendering. Execution still requires signed releases.
  Future<List<WorkerDescriptor>> syncCatalog() async {
    final loader = workerCatalogLoader;
    List<Object?> raw;
    if (loader != null) {
      raw = await loader();
    } else {
      final runtimeId = workspaceRuntimeId;
      if (runtimeId == null || runtimeId.isEmpty) {
        throw StateError(
            'Workspace runtime identity is required for catalog sync');
      }
      final uri = _baseUri().replace(
        path: _apiPath('/api/workspace-runtime/workers/catalog'),
        queryParameters: {'workspaceRuntimeId': runtimeId},
      );
      final response = await _get(uri);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Worker catalog returned HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(await _readBounded(response)));
      if (decoded is! Map ||
          decoded['workers'] is! List ||
          !const {'testing', 'beta', 'stable'}.contains(decoded['channel'])) {
        throw const FormatException('Worker catalog response is invalid');
      }
      raw = List<Object?>.from(decoded['workers'] as List);
    }
    if (raw.length > maxWorkersPerResponse ||
        raw.any((value) => value is! Map)) {
      throw const FormatException('Logical Worker catalog exceeds its bounds');
    }
    final entries = raw
        .map((value) => WorkerDescriptor.fromJson(
              Map<String, Object?>.from(value as Map),
            ))
        .toList();
    if (entries.map((entry) => entry.workerTypeId).toSet().length !=
            entries.length ||
        entries.map((entry) => entry.profileDefinitionId).toSet().length !=
            entries.length) {
      throw const FormatException('Logical Worker catalog contains duplicates');
    }
    entries.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final nextWorkers = List<WorkerDescriptor>.unmodifiable(entries);
    final unchanged = _catalogPersisted &&
        jsonEncode(_workers.map((entry) => entry.toJson()).toList()) ==
            jsonEncode(nextWorkers.map((entry) => entry.toJson()).toList());
    _workers = nextWorkers;
    if (!unchanged) await _persistCatalog();
    return _workers;
  }

  Future<List<WorkerDescriptor>> loadCatalog() async {
    if (_workers.isNotEmpty) return _workers;
    final file = _catalogFile;
    if (!await file.exists()) return const [];
    final bytes = await file.readAsBytes();
    if (bytes.length > 256 * 1024) {
      throw StateError('Logical Worker catalog cache is oversized');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! List ||
        decoded.length > maxWorkersPerResponse ||
        decoded.any((value) => value is! Map)) {
      throw const FormatException('Logical Worker catalog cache is invalid');
    }
    final cachedWorkers = List<WorkerDescriptor>.unmodifiable(
        decoded.map((value) => WorkerDescriptor.fromJson(
              Map<String, Object?>.from(value as Map),
            )));
    if (cachedWorkers.map((entry) => entry.workerTypeId).toSet().length !=
            cachedWorkers.length ||
        cachedWorkers
                .map((entry) => entry.profileDefinitionId)
                .toSet()
                .length !=
            cachedWorkers.length) {
      throw const FormatException(
          'Logical Worker catalog cache contains duplicates');
    }
    _workers = cachedWorkers;
    _catalogPersisted = true;
    return _workers;
  }

  File get _catalogFile => File(
      '${store.profilesRoot.path}${Platform.pathSeparator}worker-catalog.json');

  Future<void> _persistCatalog() async {
    final file = _catalogFile;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
        jsonEncode(_workers.map((entry) => entry.toJson()).toList()),
        flush: true);
    await temporary.rename(file.path);
    _catalogPersisted = true;
  }

  void close() => _client.close(force: true);

  /// Refreshes revocations before downloading or activating any release.
  Future<List<ToolProfileReleaseAdmission>> syncWorkerProfiles(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    _validateWorkerQuery(workerTypeId, channel);
    await store.restoreRevocations();
    await (trustRefresher ?? _refreshTrustState)();
    await store.restoreRevocations(force: true);
    await store.persistRevocations();
    final affectedWorkerTypeIds = await store.reconcileRevocations();
    if (affectedWorkerTypeIds.isNotEmpty) {
      await onRevocationsApplied?.call(affectedWorkerTypeIds);
    }
    final catalog = await listReleases(workerTypeId, channel: channel);
    final selectedChannel = catalog.channel;
    final releases = catalog.releases;
    final admissions = <ToolProfileReleaseAdmission>[];
    final selectedVersions = <String, int>{};
    final candidates = <String, ToolProfileReleaseAdmission>{};
    final unvalidatedDefinitions = <String>{};
    for (final release in releases) {
      final admission = await store.installRelease(
        releaseInput: release,
        expectedWorkerTypeId: workerTypeId,
      );
      admissions.add(admission);
      if (admission.channel != selectedChannel) {
        throw const FormatException(
          'Cloud returned a Profile outside the selected channel',
        );
      }
      final current = candidates[admission.profileDefinitionId];
      if (current == null ||
          admission.releaseVersion > current.releaseVersion) {
        candidates[admission.profileDefinitionId] = admission;
      }
    }
    for (final candidate in candidates.values) {
      final validator = candidateValidator;
      final isValidated = validator != null &&
          await validator(
            candidate,
            store.profileFile(
              candidate.profileDefinitionId,
              candidate.releaseVersion,
            ),
          );
      if (isValidated) {
        await store.activateVersion(
          candidate.profileDefinitionId,
          candidate.releaseVersion,
          selectAsStable: selectedChannel == 'stable',
        );
        selectedVersions[candidate.profileDefinitionId] =
            candidate.releaseVersion;
      } else {
        unvalidatedDefinitions.add(candidate.profileDefinitionId);
      }
    }
    await store.applyCatalogSelection(
      workerTypeId: workerTypeId,
      selectedVersionsByDefinition: selectedVersions,
      selectedChannel: selectedChannel,
      preserveDefinitionIds: unvalidatedDefinitions,
    );
    await store.enforceRetention();
    return List.unmodifiable(admissions);
  }

  Future<ToolProfileCatalogResult> listReleases(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    _validateWorkerQuery(workerTypeId, channel);
    final loader = listLoader;
    if (loader != null) {
      final result = await loader(workerTypeId, channel);
      if (result.releases.length > maxProfilesPerResponse) {
        throw StateError('Tool Profile catalog has too many releases');
      }
      if (!const {'testing', 'beta', 'stable'}.contains(result.channel)) {
        throw const FormatException(
            'Cloud selected an invalid Profile channel');
      }
      return ToolProfileCatalogResult(
        channel: result.channel,
        releases: List.unmodifiable(result.releases),
      );
    }
    final runtimeId = workspaceRuntimeId;
    if (runtimeId == null || runtimeId.isEmpty) {
      throw StateError(
          'Workspace runtime identity is required for Profile sync');
    }
    final uri = _baseUri().replace(
      path: _apiPath('/api/tool-profiles'),
      queryParameters: {
        'workerTypeId': workerTypeId,
        'workspaceRuntimeId': runtimeId,
      },
    );
    final response = await _get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
        'Tool Profile catalog returned HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(await _readBounded(response)));
    if (decoded is! Map ||
        decoded['profiles'] is! List ||
        decoded['channel'] is! String ||
        !const {'testing', 'beta', 'stable'}
            .contains(decoded['channel'] as String)) {
      throw const FormatException('Tool Profile catalog response is invalid');
    }
    final values = decoded['profiles'] as List;
    if (values.length > maxProfilesPerResponse) {
      throw StateError('Tool Profile catalog has too many releases');
    }
    if (values.any((value) => value is! Map)) {
      throw const FormatException('Tool Profile catalog entry is invalid');
    }
    return ToolProfileCatalogResult(
      channel: decoded['channel'] as String,
      releases: List.unmodifiable(
        values.map((value) => Map<String, Object?>.from(value as Map)),
      ),
    );
  }

  Future<void> _refreshTrustState() async {
    await const WorkspaceReleaseClient().refreshRevocations(
      cloudUri: cloudUri,
      authToken: authToken,
      policy: trustPolicy,
    );
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    final token = authToken;
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    return request.close().timeout(timeout);
  }

  Future<List<int>> _readBounded(HttpClientResponse response) async {
    if (response.contentLength > maxResponseBytes) {
      throw StateError('Tool Profile response exceeds the size limit');
    }
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.timeout(timeout)) {
      length += chunk.length;
      if (length > maxResponseBytes) {
        throw StateError('Tool Profile response exceeds the size limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Uri _baseUri() {
    final scheme = switch (cloudUri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'https' || 'http' => cloudUri.scheme,
      _ => throw ArgumentError('Cloud URL must use HTTP or WebSocket'),
    };
    return cloudUri.replace(
      scheme: scheme,
      path: '',
      query: null,
      fragment: null,
      userInfo: '',
    );
  }

  String _apiPath(String path) {
    final existing = cloudUri.path.replaceFirst(RegExp(r'/$'), '');
    if (existing.isEmpty ||
        existing.endsWith('/api/workspace-gateway/connect')) {
      return path;
    }
    return '$existing$path';
  }
}

void _validateWorkerQuery(String workerTypeId, String channel) {
  if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(workerTypeId) ||
      workerTypeId.length > 96 ||
      !const {'testing', 'beta', 'stable'}.contains(channel)) {
    throw ArgumentError('Tool Profile catalog query is invalid');
  }
}
