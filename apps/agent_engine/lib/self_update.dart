import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'trust_policy.dart';

class ReleasePackage {
  const ReleasePackage(
      {required this.version,
      required this.channel,
      required this.bytes,
      required this.digest,
      this.publisher,
      this.signature,
      this.minimumProtocolVersion,
      this.operatingSystem,
      this.architecture,
      this.releaseNotes,
      this.packageUrl});
  final String version;
  final String channel;
  final List<int> bytes;
  final String digest;
  final String? publisher;
  final String? signature;
  final String? minimumProtocolVersion;
  final String? operatingSystem;
  final String? architecture;
  final String? releaseNotes;
  final String? packageUrl;
}

class AgentReleaseDescriptor {
  const AgentReleaseDescriptor({
    required this.version,
    required this.channel,
    required this.packageDigest,
    required this.packageR2Key,
    this.publisher,
    this.signature,
    this.minimumProtocolVersion,
    this.operatingSystem,
    this.architecture,
    this.releaseNotes,
    this.packageUrl,
  });

  final String version;
  final String channel;
  final String packageDigest;
  final String packageR2Key;
  final String? publisher;
  final String? signature;
  final String? minimumProtocolVersion;
  final String? operatingSystem;
  final String? architecture;
  final String? releaseNotes;
  final String? packageUrl;

  factory AgentReleaseDescriptor.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('release field $key is required');
      }
      return value;
    }

    String? optionalString(String key) =>
        json[key] is String ? json[key] as String : null;

    return AgentReleaseDescriptor(
      version: requiredString('version'),
      channel: requiredString('channel'),
      packageDigest: requiredString('packageDigest'),
      packageR2Key: requiredString('packageR2Key'),
      publisher: optionalString('publisher'),
      signature: optionalString('signature'),
      minimumProtocolVersion: optionalString('minimumProtocolVersion'),
      operatingSystem: optionalString('operatingSystem'),
      architecture: optionalString('architecture'),
      releaseNotes: optionalString('releaseNotes'),
      packageUrl: optionalString('packageUrl'),
    );
  }
}

class AgentReleaseClient {
  const AgentReleaseClient({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  Future<AgentReleaseDescriptor?> latest({
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
        pathSegments: ['api', 'agent-releases', 'latest'],
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
            'agent release lookup failed with HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(await _readBody(owned, 256 * 1024));
      if (decoded is! Map || decoded['updateAvailable'] != true) {
        return null;
      }
      final release = decoded['release'];
      if (release is! Map) {
        throw const FormatException('release metadata is invalid');
      }
      return AgentReleaseDescriptor.fromJson(
          Map<String, dynamic>.from(release));
    } finally {
      owned.close();
    }
  }

  Future<ReleasePackage> download({
    required Uri cloudUri,
    required AgentReleaseDescriptor release,
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
        pathSegments: ['api', 'agent-releases', release.version, 'download'],
      ),
      authToken: authToken,
    );
    try {
      final response = owned.response;
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
            'agent release download failed with HTTP ${response.statusCode}');
      }
      final bytes = await _readBytes(owned, maxPackageBytes);
      return ReleasePackage(
        version: release.version,
        channel: release.channel,
        bytes: bytes,
        digest: release.packageDigest,
        publisher: release.publisher,
        signature: release.signature,
        minimumProtocolVersion: release.minimumProtocolVersion,
        operatingSystem: release.operatingSystem,
        architecture: release.architecture,
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
        throw StateError('agent release response exceeded $maxBytes bytes');
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

/// The externally visible state of an Agent Engine update transaction.
class AgentUpdateStatus {
  const AgentUpdateStatus({
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

typedef AgentUpdateStatusReporter = void Function(AgentUpdateStatus status);

/// Coordinates release discovery, download, verification, and activation.
///
/// The controller deliberately does not replace the running process. The
/// caller owns the platform-specific restart/bootstrap operation, while this
/// class guarantees that the update transaction is observable and that a
/// failed health check is reported as a rollback.
class AgentUpdateController {
  AgentUpdateController({
    required this.cloudUri,
    required this.currentVersion,
    required this.client,
    required this.updater,
    this.channel = 'stable',
    this.operatingSystem,
    this.architecture,
    this.authToken,
    this.reportStatus,
  });

  final Uri cloudUri;
  final String currentVersion;
  final AgentReleaseClient client;
  final AgentUpdater updater;
  final String channel;
  final String? operatingSystem;
  final String? architecture;
  final String? authToken;
  final AgentUpdateStatusReporter? reportStatus;

  AgentUpdateStatus _status = const AgentUpdateStatus(phase: 'idle');
  AgentReleaseDescriptor? _available;

  AgentUpdateStatus get status => _status;
  AgentReleaseDescriptor? get availableRelease => _available;

  Future<AgentReleaseDescriptor?> check() async {
    _publish(const AgentUpdateStatus(phase: 'checking'));
    try {
      final release = await client.latest(
        cloudUri: cloudUri,
        channel: channel,
        currentVersion: currentVersion,
        operatingSystem: operatingSystem,
        architecture: architecture,
        authToken: authToken,
      );
      _available = release;
      _publish(AgentUpdateStatus(
        phase: release == null ? 'idle' : 'available',
        version: release?.version,
      ));
      return release;
    } catch (error) {
      _publish(AgentUpdateStatus(phase: 'failed', error: '$error'));
      rethrow;
    }
  }

  Future<void> apply({
    required Future<bool> Function(File executable) healthCheck,
    Future<bool> Function()? hasActiveAssignments,
    int maxPackageBytes = 512 * 1024 * 1024,
  }) async {
    final release = _available ?? await check();
    if (release == null) {
      _publish(const AgentUpdateStatus(phase: 'idle'));
      return;
    }
    _publish(AgentUpdateStatus(phase: 'downloading', version: release.version));
    try {
      final package = await client.download(
        cloudUri: cloudUri,
        release: release,
        authToken: authToken,
        maxPackageBytes: maxPackageBytes,
      );
      if (await hasActiveAssignments?.call() ?? false) {
        _publish(AgentUpdateStatus(
          phase: 'waiting_for_tasks',
          version: release.version,
        ));
        return;
      }
      _publish(AgentUpdateStatus(phase: 'staged', version: release.version));
      await updater.apply(
        package,
        hasActiveAssignments: hasActiveAssignments,
        healthCheck: (executable) async {
          _publish(AgentUpdateStatus(
            phase: 'restarting',
            version: release.version,
          ));
          return healthCheck(executable);
        },
      );
      _available = null;
      _publish(AgentUpdateStatus(phase: 'healthy', version: release.version));
    } catch (error) {
      final message = '$error';
      _publish(AgentUpdateStatus(
        phase: message.contains('rolled back') ? 'rolled_back' : 'failed',
        version: release.version,
        error: message,
      ));
      rethrow;
    }
  }

  void _publish(AgentUpdateStatus status) {
    _status = status;
    reportStatus?.call(status);
  }
}

class AgentUpdater {
  AgentUpdater(
    this.root, {
    this.trustPolicy,
    this.requireSignature = true,
    this.currentProtocolVersion = '2.0',
  });
  final Directory root;
  final PluginTrustPolicy? trustPolicy;

  /// Unsigned releases are allowed only when explicitly opted into for local
  /// development or tests. Production update paths fail closed.
  final bool requireSignature;
  final String currentProtocolVersion;

  Future<void> apply(ReleasePackage release,
      {required Future<bool> Function(File executable) healthCheck,
      Future<bool> Function()? hasActiveAssignments,
      int maxPackageBytes = 512 * 1024 * 1024}) async {
    if (maxPackageBytes <= 0) {
      throw ArgumentError.value(
          maxPackageBytes, 'maxPackageBytes', 'must be positive');
    }
    if (release.bytes.length > maxPackageBytes) {
      throw StateError(
          'agent release exceeds the $maxPackageBytes byte package limit');
    }
    if (await hasActiveAssignments?.call() ?? false) {
      throw StateError(
          'agent release update is waiting for active assignments to finish');
    }
    final actual = sha256.convert(release.bytes).toString();
    if (actual != release.digest) {
      throw StateError('agent release digest mismatch');
    }
    final policy = trustPolicy;
    if (requireSignature && policy == null) {
      throw StateError(
          'agent release signature verification is not configured');
    }
    if (policy != null) {
      final publisher = release.publisher;
      final signature = release.signature;
      if (publisher == null ||
          signature == null ||
          !policy.verify(
            publisher: publisher,
            digest: actual,
            signature: signature,
          )) {
        throw StateError('agent release signature is not trusted');
      }
    }
    final minimumProtocol = release.minimumProtocolVersion;
    if (minimumProtocol != null &&
        !_satisfiesMinimumVersion(currentProtocolVersion, minimumProtocol)) {
      throw StateError('agent release requires an incompatible protocol');
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
              'agent release rollback is not permitted: ${release.version} < $activeVersion');
        }
        if (activeVersion == release.version && metadata['digest'] == actual) {
          return;
        }
        if (activeVersion == release.version && metadata['digest'] != actual) {
          throw StateError('agent release version is already installed');
        }
      } on StateError {
        rethrow;
      } on Object {
        throw StateError('active agent release metadata is invalid');
      }
    }
    _validateVersion(release.version);
    final staged = File(
        '${root.path}/.agent-${release.version}.staged-${DateTime.now().microsecondsSinceEpoch}');
    final active = File('${root.path}/agent.active');
    final backup = File('${root.path}/agent.previous');
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
        throw StateError('agent release health check failed; rolled back');
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
            'digest': actual,
            if (release.publisher != null) 'publisher': release.publisher,
            if (release.signature != null) 'signature': release.signature,
            if (minimumProtocol != null)
              'minimumProtocolVersion': minimumProtocol,
            if (release.operatingSystem != null)
              'operatingSystem': release.operatingSystem,
            if (release.architecture != null)
              'architecture': release.architecture,
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
      throw StateError('agent release version is invalid');
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
