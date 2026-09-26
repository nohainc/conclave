import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'v7_adapter_package_store.dart';

/// Downloads catalog releases from Cloud and hands archives to the normal
/// signed-package admission path. Cloud metadata never substitutes for the
/// signature, digest, platform, permission, and health checks in the store.
class V7AdapterCatalogClient {
  V7AdapterCatalogClient({
    required this.cloudUri,
    required this.packageStore,
    this.authToken,
    HttpClient? client,
    this.timeout = const Duration(seconds: 30),
    this.maxArchiveBytes = 50 * 1024 * 1024,
  }) : _client = client ?? HttpClient();

  final Uri cloudUri;
  final V7AdapterPackageStore packageStore;
  final String? authToken;
  final Duration timeout;
  final int maxArchiveBytes;
  final HttpClient _client;

  void close() => _client.close(force: true);

  Future<Directory?> installLatest(
    String workerTypeId, {
    String channel = 'stable',
  }) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(workerTypeId) ||
        !const {'stable', 'beta', 'development'}.contains(channel)) {
      throw ArgumentError('Adapter catalog query is invalid.');
    }
    final catalogUri = _baseUri().replace(
      path: _apiPath('/api/v7/adapters'),
      queryParameters: {
        'workerTypeId': workerTypeId,
        'platform': _currentPlatform(),
        'channel': channel,
      },
    );
    final catalogResponse = await _get(catalogUri);
    if (catalogResponse.statusCode == HttpStatus.notFound) return null;
    if (catalogResponse.statusCode != HttpStatus.ok) {
      throw StateError(
          'adapter catalog returned HTTP ${catalogResponse.statusCode}');
    }
    final catalogBytes = await _readBounded(catalogResponse, 2 * 1024 * 1024);
    final catalog = jsonDecode(utf8.decode(catalogBytes));
    if (catalog is! Map || catalog['releases'] is! List) {
      throw const FormatException('adapter catalog response is invalid');
    }
    final releases = (catalog['releases'] as List)
        .whereType<Map>()
        .map((entry) => Map<String, Object?>.from(entry))
        .where((entry) =>
            entry['workerTypeId'] == workerTypeId &&
            entry['channel'] == channel &&
            entry['supportedPlatforms'] is List &&
            (entry['supportedPlatforms'] as List).contains(_currentPlatform()))
        .toList();
    if (releases.isEmpty) return null;
    final release = releases.first;
    final version = release['version'];
    final expectedArchiveDigest = release['archiveSha256'];
    final manifest = release['manifest'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
            .hasMatch(version) ||
        expectedArchiveDigest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedArchiveDigest) ||
        manifest is! Map) {
      throw const FormatException('adapter release metadata is invalid');
    }

    final downloadUri = _baseUri().replace(
      path: _apiPath(
        '/api/v7/adapters/${Uri.encodeComponent(workerTypeId)}/versions/${Uri.encodeComponent(version)}/download',
      ),
    );
    final archiveResponse = await _get(downloadUri);
    if (archiveResponse.statusCode != HttpStatus.ok) {
      throw StateError(
          'adapter download returned HTTP ${archiveResponse.statusCode}');
    }
    final archiveBytes = await _readBounded(archiveResponse, maxArchiveBytes);
    final actualArchiveDigest = sha256.convert(archiveBytes).toString();
    if (actualArchiveDigest != expectedArchiveDigest ||
        archiveResponse.headers.value('x-conclave-archive-sha256') !=
            expectedArchiveDigest) {
      throw const FormatException('downloaded adapter archive hash is invalid');
    }
    return packageStore.installArchive(
      archiveBytes: archiveBytes,
      expectedManifest: Map<String, Object?>.from(manifest),
    );
  }

  Future<HttpClientResponse> _get(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    final token = authToken;
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request.close().timeout(timeout);
  }

  Future<List<int>> _readBounded(
      HttpClientResponse response, int byteLimit) async {
    if (response.contentLength > byteLimit) {
      throw StateError('adapter response exceeds the size limit');
    }
    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.timeout(timeout)) {
      total += chunk.length;
      if (total > byteLimit) {
        throw StateError('adapter response exceeds the size limit');
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
      _ => throw ArgumentError('Cloud URL must use HTTP or WebSocket.'),
    };
    const gatewayPath = '/api/workspace-gateway/connect';
    final prefix = cloudUri.path.endsWith(gatewayPath)
        ? cloudUri.path.substring(0, cloudUri.path.length - gatewayPath.length)
        : '';
    return Uri(
      scheme: scheme,
      host: cloudUri.host,
      port: cloudUri.hasPort ? cloudUri.port : null,
      path: prefix,
    );
  }

  String _apiPath(String path) {
    final prefix = _baseUri().path.replaceFirst(RegExp(r'/$'), '');
    return '$prefix$path';
  }

  static String _currentPlatform() {
    final os = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      _ =>
        throw UnsupportedError('This platform is not supported by adapters.'),
    };
    final arch =
        Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
    return '$os-$arch';
  }
}
