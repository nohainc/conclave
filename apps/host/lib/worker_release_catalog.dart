import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'worker_version_store.dart';
import 'worker_candidate_validator.dart';

typedef WorkerReleaseListLoader = Future<List<AvailableWorkerRelease>> Function(
  String workerTypeId,
  String channel,
);
typedef WorkerReleaseArchiveLoader = Future<List<int>> Function(
  AvailableWorkerRelease release,
);

class AvailableWorkerRelease {
  const AvailableWorkerRelease({
    required this.workerTypeId,
    required this.version,
    required this.platform,
    required this.channel,
    required this.manifest,
    required this.publishedAt,
  });

  final String workerTypeId;
  final String version;
  final String platform;
  final String channel;
  final Map<String, Object?> manifest;
  final String? publishedAt;
}

/// Fetches native Worker releases from Cloud and installs them only through
/// the signed, local WorkerVersionStore admission path.
class WorkerReleaseCatalog {
  WorkerReleaseCatalog({
    required this.cloudUri,
    required this.store,
    this.authToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
    this.releaseLoader,
    this.archiveLoader,
    this.hasActiveAssignments,
  }) : _client = client ?? HttpClient();

  final Uri cloudUri;
  final WorkerVersionStore store;
  final String? authToken;
  final Duration timeout;
  final WorkerReleaseListLoader? releaseLoader;
  final WorkerReleaseArchiveLoader? archiveLoader;
  final bool Function()? hasActiveAssignments;
  final HttpClient _client;

  void close() => _client.close(force: true);

  Future<List<AvailableWorkerRelease>> listReleases(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    final loader = releaseLoader;
    if (loader != null) {
      final releases = await loader(workerTypeId, channel);
      final filtered = releases
          .where((release) =>
              release.workerTypeId == workerTypeId &&
              release.platform == store.platform &&
              release.channel == channel)
          .toList()
        ..sort((left, right) => _compareVersions(right.version, left.version));
      return List.unmodifiable(filtered);
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(workerTypeId) ||
        !const {'stable', 'beta', 'development'}.contains(channel)) {
      throw ArgumentError('Worker release query is invalid');
    }
    final uri = _baseUri().replace(
      path: _apiPath('/api/worker-releases'),
      queryParameters: {
        'workerTypeId': workerTypeId,
        'platform': store.platform,
        'channel': channel,
      },
    );
    final response = await _get(uri);
    if (response.statusCode == HttpStatus.notFound) return const [];
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(
          'Worker release catalog returned HTTP ${response.statusCode}');
    }
    final decoded =
        jsonDecode(utf8.decode(await _readBounded(response, 2 * 1024 * 1024)));
    if (decoded is! Map || decoded['releases'] is! List) {
      throw const FormatException('Worker release catalog response is invalid');
    }
    final releases = <AvailableWorkerRelease>[];
    for (final raw in decoded['releases'] as List) {
      if (raw is! Map ||
          raw['workerTypeId'] != workerTypeId ||
          raw['platform'] != store.platform ||
          raw['channel'] != channel ||
          raw['isRevoked'] == true ||
          raw['version'] is! String ||
          raw['manifest'] is! Map) {
        continue;
      }
      releases.add(AvailableWorkerRelease(
        workerTypeId: workerTypeId,
        version: raw['version'] as String,
        platform: store.platform,
        channel: channel,
        manifest: Map<String, Object?>.from(raw['manifest'] as Map),
        publishedAt: raw['publishedAt'] as String?,
      ));
    }
    releases
        .sort((left, right) => _compareVersions(right.version, left.version));
    return List.unmodifiable(releases);
  }

  Future<AvailableWorkerRelease?> latestRelease(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    final releases = await listReleases(workerTypeId, channel: channel);
    return releases.isEmpty ? null : releases.first;
  }

  /// Returns the newest signed release this Workspace can run, optionally
  /// requiring it to be newer than the active version.
  Future<AvailableWorkerRelease?> latestCompatibleRelease(
    String workerTypeId, {
    String channel = 'stable',
    String? newerThan,
  }) async {
    for (final release in await listReleases(workerTypeId, channel: channel)) {
      if (newerThan != null &&
          _compareVersions(release.version, newerThan) <= 0) {
        continue;
      }
      if (await store.isCompatibleRelease(
        manifestInput: release.manifest,
        workerTypeId: workerTypeId,
        version: release.version,
        releasePlatform: release.platform,
        releaseChannel: release.channel,
      )) {
        return release;
      }
    }
    return null;
  }

  /// Ensures a verified native Worker runtime is installed for this type.
  Future<bool> ensureWorkerRelease(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    try {
      if (await store.activeManifest(workerTypeId) != null) return true;
    } on Object {
      // A broken active pointer is replaced only through signed admission.
    }
    final release = await latestRelease(workerTypeId, channel: channel);
    if (release == null) return false;
    await installRelease(release);
    return await store.activeManifest(workerTypeId) != null;
  }

  Future<void> installRelease(
    AvailableWorkerRelease release, {
    bool activate = true,
  }) async {
    try {
      await _installRelease(release, activate: activate);
    } on WorkerActivationDeferred {
      rethrow;
    } on WorkerCandidateValidationFailure {
      rethrow;
    } on Object {
      await store.recordCandidateFailure(
        release.workerTypeId,
        release.version,
        issueCode: WorkerIssueCode.workerInternalFailure,
        diagnostic: 'Worker candidate could not be verified or activated',
      );
      rethrow;
    }
  }

  Future<void> _installRelease(
    AvailableWorkerRelease release, {
    required bool activate,
  }) async {
    if (activate && (hasActiveAssignments?.call() ?? false)) {
      throw StateError('Worker updates wait until active assignments finish');
    }
    final uri = _baseUri().replace(
      path: _apiPath('/api/worker-releases/'
          '${Uri.encodeComponent(release.workerTypeId)}/'
          '${Uri.encodeComponent(release.version)}/'
          '${Uri.encodeComponent(release.platform)}/download'),
    );
    final loader = archiveLoader;
    final HttpClientResponse? response;
    final List<int> archive;
    if (loader != null) {
      response = null;
      archive = await loader(release);
      if (archive.length > store.maxArchiveBytes) {
        throw StateError('Worker release response exceeds its size limit');
      }
    } else {
      response = await _get(uri);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
            'Worker release download returned HTTP ${response.statusCode}');
      }
      archive = await _readBounded(response, store.maxArchiveBytes);
    }
    final manifestHash = release.manifest['archiveSha256'];
    if (manifestHash is! String ||
        sha256.convert(archive).toString() != manifestHash ||
        (response != null &&
            response.headers.value('x-conclave-archive-sha256') !=
                manifestHash)) {
      throw const FormatException('Worker release archive hash is invalid');
    }
    await store.installArchive(
      manifestInput: release.manifest,
      archiveBytes: archive,
      expectedWorkerTypeId: release.workerTypeId,
      activate: activate,
    );
  }

  Future<void> refreshAutomaticUpdate(String workerTypeId) async {
    final state = await store.releaseState(workerTypeId);
    if (state.updatePolicy != WorkerUpdatePolicy.automatic ||
        state.activeVersion == null ||
        (hasActiveAssignments?.call() ?? false)) {
      return;
    }
    final latest = await latestRelease(workerTypeId);
    final previousFailure = await store.lastCandidateFailure(workerTypeId);
    if (latest != null &&
        previousFailure?['version'] != latest.version &&
        _compareVersions(latest.version, state.activeVersion!) > 0) {
      await installRelease(latest);
    }
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    final token = authToken;
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request.close().timeout(timeout);
  }

  Future<List<int>> _readBounded(HttpClientResponse response, int limit) async {
    if (response.contentLength > limit) {
      throw StateError('Worker release response exceeds its size limit');
    }
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.timeout(timeout)) {
      length += chunk.length;
      if (length > limit) {
        throw StateError('Worker release response exceeds its size limit');
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

int _compareVersions(String left, String right) {
  final leftCore =
      left.split(RegExp(r'[+-]')).first.split('.').map(int.parse).toList();
  final rightCore =
      right.split(RegExp(r'[+-]')).first.split('.').map(int.parse).toList();
  for (var index = 0; index < 3; index++) {
    final comparison = leftCore[index].compareTo(rightCore[index]);
    if (comparison != 0) return comparison;
  }
  return left.compareTo(right);
}
