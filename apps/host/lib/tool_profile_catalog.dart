import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'self_update.dart';
import 'tool_profile_release_store.dart';
import 'tool_profile_release_verifier.dart';
import 'worker_trust_policy.dart';

typedef ToolProfileListLoader = Future<ToolProfileCatalogResult> Function(
  String workerTypeId,
  String defaultChannel,
);
typedef LogicalWorkerCatalogLoader = Future<List<Object?>> Function();

class LogicalWorkerCatalogEntry {
  const LogicalWorkerCatalogEntry({
    required this.workerTypeId,
    required this.displayName,
    required this.description,
    required this.profileDefinitionId,
    required this.providerToolName,
    required this.engineFamily,
    required this.releaseStage,
    required this.capabilities,
    required this.sortOrder,
  });

  final String workerTypeId;
  final String displayName;
  final String description;
  final String profileDefinitionId;
  final String providerToolName;
  final String engineFamily;
  final String releaseStage;
  final List<String> capabilities;
  final int sortOrder;

  factory LogicalWorkerCatalogEntry.fromJson(Map<String, Object?> json) {
    const fields = {
      'workerTypeId',
      'displayName',
      'description',
      'profileDefinitionId',
      'providerToolName',
      'engineFamily',
      'visibilityState',
      'releaseStage',
      'capabilities',
      'sortOrder',
    };
    const capabilities = {
      'text',
      'local_file',
      'workstream_read',
      'workstream_write',
      'durable_session',
      'image',
      'audio',
      'video',
    };
    final workerTypeId = json['workerTypeId'];
    final displayName = json['displayName'];
    final description = json['description'];
    final definitionId = json['profileDefinitionId'];
    final toolName = json['providerToolName'];
    final engineFamily = json['engineFamily'];
    final visibility = json['visibilityState'];
    final stage = json['releaseStage'];
    final values = json['capabilities'];
    final sortOrder = json['sortOrder'];
    if (json.keys.any((key) => !fields.contains(key)) ||
        workerTypeId is! String ||
        !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(workerTypeId) ||
        workerTypeId.length > 96 ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 120 ||
        description is! String ||
        description.length > 500 ||
        definitionId is! String ||
        !RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(definitionId) ||
        toolName is! String ||
        toolName.isEmpty ||
        toolName.length > 64 ||
        engineFamily != 'cli' ||
        visibility != 'visible' ||
        !const {'testing', 'beta', 'stable'}.contains(stage) ||
        values is! List ||
        values.length > 32 ||
        values.any(
            (value) => value is! String || !capabilities.contains(value)) ||
        values.toSet().length != values.length ||
        sortOrder is! int ||
        sortOrder < 0 ||
        sortOrder > 10000) {
      throw const FormatException('Logical Worker catalog entry is invalid');
    }
    return LogicalWorkerCatalogEntry(
      workerTypeId: workerTypeId,
      displayName: displayName,
      description: description,
      profileDefinitionId: definitionId,
      providerToolName: toolName,
      engineFamily: 'cli',
      releaseStage: stage as String,
      capabilities: List.unmodifiable(values.cast<String>()),
      sortOrder: sortOrder,
    );
  }

  Map<String, Object?> toJson() => {
        'workerTypeId': workerTypeId,
        'displayName': displayName,
        'description': description,
        'profileDefinitionId': profileDefinitionId,
        'providerToolName': providerToolName,
        'engineFamily': engineFamily,
        'visibilityState': 'visible',
        'releaseStage': releaseStage,
        'capabilities': capabilities,
        'sortOrder': sortOrder,
      };
}

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
  final LogicalWorkerCatalogLoader? workerCatalogLoader;
  final ToolProfileTrustRefresher? trustRefresher;
  final ToolProfileCandidateValidator? candidateValidator;
  final ToolProfileRevocationHandler? onRevocationsApplied;
  final HttpClient _client;
  List<LogicalWorkerCatalogEntry> _workers = const [];
  List<LogicalWorkerCatalogEntry> get workers => _workers;

  LogicalWorkerCatalogEntry? entryForWorker(String workerTypeId) =>
      _workers.where((entry) => entry.workerTypeId == workerTypeId).firstOrNull;

  String? profileDefinitionForWorker(String workerTypeId) =>
      entryForWorker(workerTypeId)?.profileDefinitionId;

  /// Fetches the approved, Cloud-selected catalog; a bounded local snapshot is
  /// retained for offline rendering. Execution still requires signed releases.
  Future<List<LogicalWorkerCatalogEntry>> syncCatalog() async {
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
        path: _apiPath('/api/tool-profiles'),
        queryParameters: {'workspaceRuntimeId': runtimeId},
      );
      final response = await _get(uri);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
            'Logical Worker catalog returned HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(await _readBounded(response)));
      if (decoded is! Map ||
          decoded['workers'] is! List ||
          !const {'testing', 'beta', 'stable'}.contains(decoded['channel'])) {
        throw const FormatException(
            'Logical Worker catalog response is invalid');
      }
      raw = List<Object?>.from(decoded['workers'] as List);
    }
    if (raw.length > maxWorkersPerResponse ||
        raw.any((value) => value is! Map)) {
      throw const FormatException('Logical Worker catalog exceeds its bounds');
    }
    final entries = raw
        .map((value) => LogicalWorkerCatalogEntry.fromJson(
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
    _workers = List.unmodifiable(entries);
    await _persistCatalog();
    return _workers;
  }

  Future<List<LogicalWorkerCatalogEntry>> loadCatalog() async {
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
    final cachedWorkers = List<LogicalWorkerCatalogEntry>.unmodifiable(
        decoded.map((value) => LogicalWorkerCatalogEntry.fromJson(
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
