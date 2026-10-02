import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'worker_trust_policy.dart';

class ReleasePackage {
  const ReleasePackage(
      {required this.version,
      required this.channel,
      required this.bytes,
      required this.digest,
      this.publisher,
      this.signingKeyId,
      this.signature,
      this.minimumProtocolVersion,
      this.minSupportedWorkspaceVersion,
      this.operatingSystem,
      this.architecture,
      this.supportedOS = const [],
      this.supportedArch = const [],
      this.releaseNotes,
      this.packageUrl});
  final String version;
  final String channel;
  final List<int> bytes;
  final String digest;
  final String? publisher;
  final String? signingKeyId;
  final String? signature;
  final String? minimumProtocolVersion;
  final String? minSupportedWorkspaceVersion;
  final String? operatingSystem;
  final String? architecture;
  final List<String> supportedOS;
  final List<String> supportedArch;
  final String? releaseNotes;
  final String? packageUrl;
}

class WorkspaceReleaseDescriptor {
  const WorkspaceReleaseDescriptor({
    required this.version,
    required this.channel,
    required this.packageDigest,
    required this.packageR2Key,
    this.publisher,
    this.signingKeyId,
    this.signature,
    this.minimumProtocolVersion,
    this.minSupportedWorkspaceVersion,
    this.operatingSystem,
    this.architecture,
    this.supportedOS = const [],
    this.supportedArch = const [],
    this.releaseNotes,
    this.packageUrl,
  });

  final String version;
  final String channel;
  final String packageDigest;
  final String packageR2Key;
  final String? publisher;
  final String? signingKeyId;
  final String? signature;
  final String? minimumProtocolVersion;
  final String? minSupportedWorkspaceVersion;
  final String? operatingSystem;
  final String? architecture;
  final List<String> supportedOS;
  final List<String> supportedArch;
  final String? releaseNotes;
  final String? packageUrl;

  factory WorkspaceReleaseDescriptor.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('release field $key is required');
      }
      return value;
    }

    String? optionalString(String key) =>
        json[key] is String ? json[key] as String : null;

    return WorkspaceReleaseDescriptor(
      version: requiredString('version'),
      channel: requiredString('channel'),
      packageDigest: requiredString('packageDigest'),
      packageR2Key: requiredString('packageR2Key'),
      publisher: optionalString('publisher'),
      signingKeyId: optionalString('signingKeyId'),
      signature: optionalString('signature'),
      minimumProtocolVersion: optionalString('minimumProtocolVersion'),
      minSupportedWorkspaceVersion:
          optionalString('minSupportedWorkspaceVersion'),
      operatingSystem: optionalString('operatingSystem'),
      architecture: optionalString('architecture'),
      supportedOS: json['supportedOS'] is List
          ? (json['supportedOS'] as List).whereType<String>().toList()
          : const [],
      supportedArch: json['supportedArch'] is List
          ? (json['supportedArch'] as List).whereType<String>().toList()
          : const [],
      releaseNotes: optionalString('releaseNotes'),
      packageUrl: optionalString('packageUrl'),
    );
  }
}

class WorkspaceReleaseClient {
  const WorkspaceReleaseClient({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  Future<void> refreshRevocations({
    required Uri cloudUri,
    required String? authToken,
    required WorkerTrustPolicy policy,
  }) async {
    final owned = await _request(
      cloudUri.replace(
        scheme: _httpScheme(cloudUri),
        pathSegments: ['api', 'release-trust'],
      ),
      authToken: authToken,
    );
    try {
      if (owned.response.statusCode != HttpStatus.ok) {
        throw StateError(
            'release trust refresh failed with HTTP ${owned.response.statusCode}');
      }
      final decoded = jsonDecode(await _readBody(owned, 1024 * 1024));
      if (decoded is! Map ||
          decoded['revokedKeyIds'] is! List ||
          decoded['revokedWorkspaceReleases'] is! List ||
          decoded['revokedToolProfiles'] is! List) {
        throw const FormatException('release trust response is invalid');
      }
      final digests = <String>{};
      final releases = <String>{};
      for (final row in [
        ...decoded['revokedWorkspaceReleases'] as List,
        ...decoded['revokedToolProfiles'] as List,
      ].whereType<Map>()) {
        if (row['packageDigest'] is String) {
          digests.add(row['packageDigest'] as String);
        } else if (row['payloadDigest'] is String) {
          digests.add(row['payloadDigest'] as String);
        }
        if (row['version'] is String) {
          releases.add('workspace@${row['version']}');
        } else if (row['profileDefinitionId'] is String &&
            row['releaseVersion'] is int) {
          releases.add(
            '${row['profileDefinitionId']}@${row['releaseVersion']}',
          );
        }
      }
      policy.updateRevocations(
        digests: digests,
        keyIds: (decoded['revokedKeyIds'] as List).whereType<String>().toSet(),
        releaseIds: releases,
      );
    } finally {
      owned.close();
    }
  }

  Future<WorkspaceReleaseDescriptor?> latest({
    required Uri cloudUri,
    required String channel,
    required String currentVersion,
    String? operatingSystem,
    String? architecture,
    String? authToken,
  }) async {
    final owned = await _request(
      cloudUri.replace(
        scheme: _httpScheme(cloudUri),
        pathSegments: ['api', 'workspace-releases', 'latest'],
        queryParameters: {
          'channel': channel,
          'currentVersion': currentVersion,
          if (operatingSystem != null) 'os': operatingSystem,
          if (architecture != null) 'arch': architecture,
        },
      ),
      authToken: authToken,
    );
    try {
      final response = owned.response;
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
            'Workspace release lookup failed with HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(await _readBody(owned, 256 * 1024));
      if (decoded is! Map || decoded['updateAvailable'] != true) {
        return null;
      }
      final release = decoded['release'];
      if (release is! Map) {
        throw const FormatException('release metadata is invalid');
      }
      return WorkspaceReleaseDescriptor.fromJson(
          Map<String, dynamic>.from(release));
    } finally {
      owned.close();
    }
  }

  Future<ReleasePackage> download({
    required Uri cloudUri,
    required WorkspaceReleaseDescriptor release,
    String? authToken,
    int maxPackageBytes = 512 * 1024 * 1024,
  }) async {
    if (maxPackageBytes <= 0) {
      throw ArgumentError.value(
          maxPackageBytes, 'maxPackageBytes', 'must be positive');
    }
    final owned = await _request(
      cloudUri.replace(
        scheme: _httpScheme(cloudUri),
        pathSegments: [
          'api',
          'workspace-releases',
          release.version,
          'download'
        ],
      ),
      authToken: authToken,
    );
    try {
      final response = owned.response;
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
            'Workspace release download failed with HTTP ${response.statusCode}');
      }
      final bytes = await _readBytes(owned, maxPackageBytes);
      return ReleasePackage(
        version: release.version,
        channel: release.channel,
        bytes: bytes,
        digest: release.packageDigest,
        publisher: release.publisher,
        signingKeyId: release.signingKeyId,
        signature: release.signature,
        minimumProtocolVersion: release.minimumProtocolVersion,
        minSupportedWorkspaceVersion: release.minSupportedWorkspaceVersion,
        operatingSystem: release.operatingSystem,
        architecture: release.architecture,
        supportedOS: release.supportedOS,
        supportedArch: release.supportedArch,
        releaseNotes: release.releaseNotes,
        packageUrl: release.packageUrl,
      );
    } finally {
      owned.close();
    }
  }

  Future<_OwnedResponse> _request(Uri uri, {String? authToken}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      if (authToken != null && authToken.isNotEmpty) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
      }
      final response = await request.close().timeout(timeout);
      return _OwnedResponse(response, client);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  String _httpScheme(Uri uri) => uri.scheme == 'wss' ? 'https' : 'http';

  Future<String> _readBody(_OwnedResponse owned, int maxBytes) async {
    final bytes = await _readBytes(owned, maxBytes);
    return utf8.decode(bytes);
  }

  Future<List<int>> _readBytes(_OwnedResponse owned, int maxBytes) async {
    final bytes = <int>[];
    await for (final chunk in owned.response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw StateError('Workspace release response exceeded $maxBytes bytes');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }
}

class _OwnedResponse {
  _OwnedResponse(this._response, this._client);
  final HttpClientResponse _response;
  final HttpClient _client;

  HttpClientResponse get response => _response;

  void close() => _client.close(force: true);
}

/// The externally visible state of an Workspace update transaction.
class WorkspaceUpdateStatus {
  const WorkspaceUpdateStatus({
    required this.phase,
    this.version,
    this.error,
  });

  final String phase;
  final String? version;
  final String? error;

  Map<String, Object?> toJson() => {
        'phase': phase,
        if (version != null) 'version': version,
        if (error != null) 'error': error,
      };
}

typedef WorkspaceUpdateStatusReporter = void Function(
    WorkspaceUpdateStatus status);
typedef WorkspaceRestartBootstrap = Future<bool> Function(File executable);

/// Coordinates release discovery, download, verification, and activation.
///
/// The controller deliberately does not replace the running process. The
/// caller owns the platform-specific restart/bootstrap operation, while this
/// class guarantees that the update transaction is observable and that a
/// failed health check is reported as a rollback.
class WorkspaceUpdateController {
  WorkspaceUpdateController({
    required this.cloudUri,
    required this.currentVersion,
    required this.client,
    required this.updater,
    this.channel = 'stable',
    this.operatingSystem,
    this.architecture,
    this.authToken,
    this.reportStatus,
    this.restartBootstrap,
  });

  final Uri cloudUri;
  final String currentVersion;
  final WorkspaceReleaseClient client;
  final WorkspaceUpdater updater;
  final String channel;
  final String? operatingSystem;
  final String? architecture;
  final String? authToken;
  final WorkspaceUpdateStatusReporter? reportStatus;
  final WorkspaceRestartBootstrap? restartBootstrap;

  WorkspaceUpdateStatus _status = const WorkspaceUpdateStatus(phase: 'idle');
  WorkspaceReleaseDescriptor? _available;

  WorkspaceUpdateStatus get status => _status;
  WorkspaceReleaseDescriptor? get availableRelease => _available;

  /// Accepts a release announcement delivered over the authenticated Cloud
  /// connection. The announcement is only made available for an explicit
  /// apply action; receiving it never mutates the running installation.
  WorkspaceReleaseDescriptor acceptAvailable(Map<String, Object?> payload) {
    final release = WorkspaceReleaseDescriptor.fromJson(
      Map<String, dynamic>.from(payload),
    );
    _validateAnnouncementCompatibility(release);
    _available = release;
    _publish(
        WorkspaceUpdateStatus(phase: 'available', version: release.version));
    return release;
  }

  Future<WorkspaceReleaseDescriptor?> check() async {
    _publish(const WorkspaceUpdateStatus(phase: 'checking'));
    try {
      final policy = updater.trustPolicy;
      if (policy != null) {
        await client.refreshRevocations(
          cloudUri: cloudUri,
          authToken: authToken,
          policy: policy,
        );
      }
      final release = await client.latest(
        cloudUri: cloudUri,
        channel: channel,
        currentVersion: currentVersion,
        operatingSystem: operatingSystem,
        architecture: architecture,
        authToken: authToken,
      );
      if (release != null) _validateAnnouncementCompatibility(release);
      _available = release;
      _publish(WorkspaceUpdateStatus(
        phase: release == null ? 'idle' : 'available',
        version: release?.version,
      ));
      return release;
    } catch (error) {
      _publish(WorkspaceUpdateStatus(phase: 'failed', error: '$error'));
      rethrow;
    }
  }

  Future<void> apply({
    required Future<bool> Function(File executable) healthCheck,
    Future<bool> Function()? hasActiveAssignments,
    WorkspaceRestartBootstrap? restartBootstrap,
    int maxPackageBytes = 512 * 1024 * 1024,
  }) async {
    final bootstrap = restartBootstrap ?? this.restartBootstrap;
    final release = _available ?? await check();
    if (release == null) {
      _publish(const WorkspaceUpdateStatus(phase: 'idle'));
      return;
    }
    _publish(
        WorkspaceUpdateStatus(phase: 'downloading', version: release.version));
    try {
      final policy = updater.trustPolicy;
      if (policy != null) {
        await client.refreshRevocations(
          cloudUri: cloudUri,
          authToken: authToken,
          policy: policy,
        );
      }
      final package = await client.download(
        cloudUri: cloudUri,
        release: release,
        authToken: authToken,
        maxPackageBytes: maxPackageBytes,
      );
      if (await hasActiveAssignments?.call() ?? false) {
        _publish(WorkspaceUpdateStatus(
          phase: 'waiting_for_tasks',
          version: release.version,
        ));
        return;
      }
      _publish(
          WorkspaceUpdateStatus(phase: 'staged', version: release.version));
      if (bootstrap == null) {
        _publish(WorkspaceUpdateStatus(
          phase: 'restart_required',
          version: release.version,
        ));
        return;
      }
      await updater.apply(
        package,
        hasActiveAssignments: hasActiveAssignments,
        onActivated: bootstrap,
        healthCheck: (executable) async {
          _publish(WorkspaceUpdateStatus(
            phase: 'restarting',
            version: release.version,
          ));
          return healthCheck(executable);
        },
      );
      _available = null;
      _publish(
          WorkspaceUpdateStatus(phase: 'healthy', version: release.version));
    } catch (error) {
      final message = '$error';
      _publish(WorkspaceUpdateStatus(
        phase: message.contains('rolled back') ? 'rolled_back' : 'failed',
        version: release.version,
        error: message,
      ));
      rethrow;
    }
  }

  void _publish(WorkspaceUpdateStatus status) {
    _status = status;
    reportStatus?.call(status);
  }

  void _validateAnnouncementCompatibility(WorkspaceReleaseDescriptor release) {
    if (!_isVersion(release.version) || !_isVersion(currentVersion)) {
      throw StateError('Workspace release version is invalid');
    }
    if (_compareVersions(release.version, currentVersion) <= 0) {
      throw StateError(
          'Workspace release downgrade or duplicate is not permitted: ${release.version} <= $currentVersion');
    }
    final minimum = release.minSupportedWorkspaceVersion;
    if (minimum != null &&
        (!_isVersion(minimum) ||
            _compareVersions(currentVersion, minimum) < 0)) {
      throw StateError(
          'Workspace release requires a newer Workspace: $minimum');
    }
  }

  bool _isVersion(String value) =>
      RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(value);

  int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < 3; index++) {
      if (leftParts[index] != rightParts[index]) {
        return leftParts[index].compareTo(rightParts[index]);
      }
    }
    return 0;
  }

  List<int> _versionParts(String value) => value
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? -1)
      .toList(growable: false);
}

class WorkspaceUpdater {
  WorkspaceUpdater(
    this.root, {
    this.trustPolicy,
    this.requireSignature = true,
    this.currentProtocolVersion = '2.0',
  });
  final Directory root;
  final WorkerTrustPolicy? trustPolicy;

  /// Unsigned releases are allowed only when explicitly opted into for local
  /// development or tests. Production update paths fail closed.
  final bool requireSignature;
  final String currentProtocolVersion;

  File get activeExecutable => File('${root.path}/workspace.active');

  Future<void> apply(ReleasePackage release,
      {required Future<bool> Function(File executable) healthCheck,
      WorkspaceRestartBootstrap? onActivated,
      Future<bool> Function()? hasActiveAssignments,
      int maxPackageBytes = 512 * 1024 * 1024}) async {
    if (maxPackageBytes <= 0) {
      throw ArgumentError.value(
          maxPackageBytes, 'maxPackageBytes', 'must be positive');
    }
    if (release.bytes.length > maxPackageBytes) {
      throw StateError(
          'Workspace release exceeds the $maxPackageBytes byte package limit');
    }
    if (await hasActiveAssignments?.call() ?? false) {
      throw StateError(
          'Workspace release update is waiting for active assignments to finish');
    }
    final actual = sha256.convert(release.bytes).toString();
    final canonicalDigest = 'sha256:$actual';
    if (release.digest != actual && release.digest != canonicalDigest) {
      throw StateError('Workspace release digest mismatch');
    }
    final machineOperatingSystem = Platform.operatingSystem;
    final machineArchitecture =
        Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
    if ((release.supportedOS.isNotEmpty &&
            !release.supportedOS.contains(machineOperatingSystem)) ||
        (release.supportedArch.isNotEmpty &&
            !release.supportedArch.contains(machineArchitecture))) {
      throw StateError('Workspace release does not support this platform');
    }
    final policy = trustPolicy;
    if (requireSignature && policy == null) {
      throw StateError(
          'Workspace release signature verification is not configured');
    }
    if (policy != null) {
      final publisher = release.publisher;
      final signature = release.signature;
      final signingKeyId = release.signingKeyId;
      if (publisher == null ||
          signingKeyId == null ||
          signature == null ||
          !await policy.verifyWorkspaceRelease(
            publisher: publisher,
            signingKeyId: signingKeyId,
            digest: release.digest,
            signature: signature,
            metadata: {
              'version': release.version,
              'channel': release.channel,
              'minSupportedWorkspaceVersion':
                  release.minSupportedWorkspaceVersion,
              'supportedOS': release.supportedOS,
              'supportedArch': release.supportedArch,
              'releaseNotes': release.releaseNotes,
            },
          )) {
        throw StateError('Workspace release signature is not trusted');
      }
    }
    final minimumProtocol = release.minimumProtocolVersion;
    if (minimumProtocol != null &&
        !_satisfiesMinimumVersion(currentProtocolVersion, minimumProtocol)) {
      throw StateError('Workspace release requires an incompatible protocol');
    }
    await root.create(recursive: true);
    final releaseMetadata = File('${root.path}/release.json');
    if (await releaseMetadata.exists()) {
      try {
        final metadata =
            jsonDecode(await releaseMetadata.readAsString()) as Map;
        final activeVersion = metadata['version'];
        if (activeVersion is String &&
            _compareVersions(release.version, activeVersion) < 0) {
          throw StateError(
              'Workspace release rollback is not permitted: ${release.version} < $activeVersion');
        }
        if (activeVersion == release.version &&
            metadata['digest'] == release.digest) {
          return;
        }
        if (activeVersion == release.version &&
            metadata['digest'] != release.digest) {
          throw StateError('Workspace release version is already installed');
        }
      } on StateError {
        rethrow;
      } on Object {
        throw StateError('active Workspace release metadata is invalid');
      }
    }
    _validateVersion(release.version);
    final staged = File(
        '${root.path}/.workspace-${release.version}.staged-${DateTime.now().microsecondsSinceEpoch}');
    final active = activeExecutable;
    final backup = File('${root.path}/workspace.previous');
    final hadPrevious = await active.exists();
    try {
      await staged.writeAsBytes(release.bytes, flush: true);
      if (await active.exists()) {
        if (await backup.exists()) await backup.delete();
        await active.rename(backup.path);
      }
      await staged.rename(active.path);
      if (!await healthCheck(active)) {
        if (await active.exists()) await active.delete();
        if (await backup.exists()) await backup.rename(active.path);
        throw StateError('Workspace release health check failed; rolled back');
      }
      if (onActivated != null && !await onActivated(active)) {
        if (await active.exists()) await active.delete();
        if (await backup.exists()) await backup.rename(active.path);
        throw StateError('Workspace release restart failed; rolled back');
      }
    } catch (_) {
      if (await staged.exists()) await staged.delete();
      rethrow;
    }
    final metadata = File('${root.path}/release.json');
    final metadataTemp =
        File('${metadata.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await metadataTemp.writeAsString(
          jsonEncode({
            'version': release.version,
            'channel': release.channel,
            'digest': release.digest,
            if (release.publisher != null) 'publisher': release.publisher,
            if (release.signingKeyId != null)
              'signingKeyId': release.signingKeyId,
            if (release.signature != null) 'signature': release.signature,
            if (minimumProtocol != null)
              'minimumProtocolVersion': minimumProtocol,
            if (release.operatingSystem != null)
              'operatingSystem': release.operatingSystem,
            if (release.architecture != null)
              'architecture': release.architecture,
            'supportedOS': release.supportedOS,
            'supportedArch': release.supportedArch,
            if (release.minSupportedWorkspaceVersion != null)
              'minSupportedWorkspaceVersion':
                  release.minSupportedWorkspaceVersion,
            if (release.releaseNotes != null)
              'releaseNotes': release.releaseNotes,
            if (release.packageUrl != null) 'packageUrl': release.packageUrl,
          }),
          flush: true);
      await metadataTemp.rename(metadata.path);
    } catch (_) {
      if (await metadataTemp.exists()) await metadataTemp.delete();
      if (await active.exists()) await active.delete();
      if (hadPrevious && await backup.exists()) {
        await backup.rename(active.path);
      }
      rethrow;
    }
  }

  void _validateVersion(String version) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$').hasMatch(version)) {
      throw StateError('Workspace release version is invalid');
    }
  }

  bool _satisfiesMinimumVersion(String current, String minimum) {
    final currentParts = _versionParts(current);
    final minimumParts = _versionParts(minimum);
    for (var index = 0; index < 3; index++) {
      if (currentParts[index] != minimumParts[index]) {
        return currentParts[index] > minimumParts[index];
      }
    }
    return true;
  }

  int _compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    for (var index = 0; index < 3; index++) {
      if (leftParts[index] != rightParts[index]) {
        return leftParts[index].compareTo(rightParts[index]);
      }
    }
    return 0;
  }

  List<int> _versionParts(String version) => version
      .split('.')
      .take(3)
      .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .followedBy(const [0, 0, 0])
      .take(3)
      .toList();
}
