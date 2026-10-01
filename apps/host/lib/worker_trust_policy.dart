import 'dart:convert';

import 'package:cryptography/cryptography.dart';

enum WorkerPermission {
  readWorkspace,
  writeWorkspace,
  shell,
  network,
  networkOpenAi,
  networkGoogle,
  networkAnthropic,
  credentials
}

extension WorkerPermissionWire on WorkerPermission {
  String get wireName => switch (this) {
        WorkerPermission.readWorkspace => 'workspace:read',
        WorkerPermission.writeWorkspace => 'workspace:write',
        WorkerPermission.shell => 'shell:execute',
        WorkerPermission.network => 'network:outbound',
        WorkerPermission.networkOpenAi => 'network:openai',
        WorkerPermission.networkGoogle => 'network:google',
        WorkerPermission.networkAnthropic => 'network:anthropic',
        WorkerPermission.credentials => 'credentials:read',
      };
}

WorkerPermission parseWorkerPermission(String value) => switch (value) {
      'readWorkspace' || 'workspace:read' => WorkerPermission.readWorkspace,
      'writeWorkspace' || 'workspace:write' => WorkerPermission.writeWorkspace,
      'shell' || 'shell:execute' => WorkerPermission.shell,
      'network' || 'network:outbound' => WorkerPermission.network,
      'network:openai' => WorkerPermission.networkOpenAi,
      'network:google' => WorkerPermission.networkGoogle,
      'network:anthropic' => WorkerPermission.networkAnthropic,
      'credentials' || 'credentials:read' => WorkerPermission.credentials,
      _ => throw StateError('unknown worker permission: $value'),
    };

Set<WorkerPermission> parseConfiguredWorkerPermissions(String? configured) {
  if (configured == null || configured.trim().isEmpty) return {};
  return configured
      .split(',')
      .map((permission) => permission.trim())
      .where((permission) => permission.isNotEmpty)
      .map(parseWorkerPermission)
      .toSet();
}

/// Public verification roots shipped with Workspace. Values are base64 raw
/// Ed25519 public keys, keyed by publisher and explicit key ID. This class
/// never accepts signing secrets.
class WorkerTrustPolicy {
  WorkerTrustPolicy({
    Map<String, Map<String, String>> trustedPublicKeys = const {},
    this.allowUnsignedDevelopmentReleases = false,
    Set<String> revokedDigests = const {},
    Set<String> revokedPublishers = const {},
    Set<String> revokedKeyIds = const {},
    Set<String> revokedReleaseIds = const {},
  })  : trustedPublicKeys = Map.unmodifiable({
          for (final entry in trustedPublicKeys.entries)
            entry.key: Map<String, String>.unmodifiable(entry.value),
        }),
        _revokedDigests = Set.of(revokedDigests),
        _revokedPublishers = Set.of(revokedPublishers),
        _revokedKeyIds = Set.of(revokedKeyIds),
        _revokedReleaseIds = Set.of(revokedReleaseIds);

  final Map<String, Map<String, String>> trustedPublicKeys;

  /// Permits only the explicit local-development manifest marker. Workspace
  /// enables this only in debug builds when its development define is set.
  final bool allowUnsignedDevelopmentReleases;
  Set<String> _revokedDigests;
  Set<String> _revokedPublishers;
  Set<String> _revokedKeyIds;
  Set<String> _revokedReleaseIds;

  Set<String> get revokedDigests => Set.unmodifiable(_revokedDigests);
  Set<String> get revokedPublishers => Set.unmodifiable(_revokedPublishers);
  Set<String> get revokedKeyIds => Set.unmodifiable(_revokedKeyIds);
  Set<String> get revokedReleaseIds => Set.unmodifiable(_revokedReleaseIds);

  bool hasTrustedSigningKey(String publisher, String signingKeyId) =>
      trustedPublicKeys[publisher]?.containsKey(signingKeyId) ?? false;

  bool isToolProfileReleaseRevoked({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String releaseId,
  }) =>
      _revokedDigests.contains(digest) ||
      _revokedPublishers.contains(publisher) ||
      _revokedKeyIds.contains(signingKeyId) ||
      _revokedReleaseIds.contains(releaseId);

  void updateRevocations({
    Set<String> digests = const {},
    Set<String> publishers = const {},
    Set<String> keyIds = const {},
    Set<String> releaseIds = const {},
  }) {
    _revokedDigests = Set.of(digests);
    _revokedPublishers = Set.of(publishers);
    _revokedKeyIds = Set.of(keyIds);
    _revokedReleaseIds = Set.of(releaseIds);
  }

  Future<bool> verify({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String signature,
  }) async {
    if (_revokedDigests.contains(digest) ||
        _revokedPublishers.contains(publisher) ||
        _revokedKeyIds.contains(signingKeyId)) {
      return false;
    }
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode('conclave-workspace-release-v1\n$digest'),
    );
  }

  /// Verifies a signed Tool Profile Release envelope. Lifecycle state is
  /// checked by the caller; it is deliberately absent from signed behavior.
  Future<bool> verifyToolProfileRelease({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String releaseId,
    required String signature,
    required String message,
  }) async {
    if (isToolProfileReleaseRevoked(
      publisher: publisher,
      signingKeyId: signingKeyId,
      digest: digest,
      releaseId: releaseId,
    )) {
      return false;
    }
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode(message),
    );
  }

  Future<bool> verifyAdapterManifest({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String signature,
    required Map<String, Object?> manifest,
  }) async {
    final releaseId =
        '${manifest['workerTypeId']}@${manifest['adapterVersion']}';
    if (_revokedDigests.contains(digest) ||
        _revokedPublishers.contains(publisher) ||
        _revokedKeyIds.contains(signingKeyId) ||
        _revokedReleaseIds.contains(releaseId)) {
      return false;
    }
    final unsigned = Map<String, Object?>.from(manifest)..remove('signature');
    final payload = 'conclave-v7-adapter-release-v1\n$digest\n'
        '${canonicalJson(unsigned)}';
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode(payload),
    );
  }

  /// Verifies signed, provider-neutral Worker release manifest v2 metadata.
  Future<bool> verifyWorkerReleaseManifest(
    Map<String, Object?> manifest,
  ) async {
    final publisher = manifest['publisher'];
    final signingKeyId = manifest['signingKeyId'];
    final digest = manifest['packageDigest'];
    final workerTypeId = manifest['workerTypeId'];
    final workerVersion = manifest['workerVersion'];
    final signature = manifest['signature'];
    if (publisher is! String ||
        signingKeyId is! String ||
        digest is! String ||
        workerTypeId is! String ||
        workerVersion is! String ||
        signature is! String) {
      return false;
    }
    if (allowUnsignedDevelopmentReleases &&
        publisher == 'local-development' &&
        manifest['releaseChannel'] == 'development' &&
        signingKeyId == 'unsigned-development' &&
        signature == 'unsigned-development' &&
        !_revokedDigests.contains(digest) &&
        !_revokedPublishers.contains(publisher) &&
        !_revokedKeyIds.contains(signingKeyId) &&
        !_revokedReleaseIds.contains('$workerTypeId@$workerVersion')) {
      return true;
    }
    if (_revokedDigests.contains(digest) ||
        _revokedPublishers.contains(publisher) ||
        _revokedKeyIds.contains(signingKeyId) ||
        _revokedReleaseIds.contains('$workerTypeId@$workerVersion')) {
      return false;
    }
    final unsigned = Map<String, Object?>.from(manifest)..remove('signature');
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode(
        'conclave-worker-release-manifest-v2\n${canonicalJson(unsigned)}',
      ),
    );
  }

  Future<bool> verifyHostRelease({
    required String publisher,
    required String signingKeyId,
    required String digest,
    required String signature,
    required Map<String, Object?> metadata,
  }) async {
    if (_revokedDigests.contains(digest) ||
        _revokedPublishers.contains(publisher) ||
        _revokedKeyIds.contains(signingKeyId) ||
        _revokedReleaseIds.contains('workspace@${metadata['version']}')) {
      return false;
    }
    final payload = 'conclave-workspace-release-metadata-v1\n'
        '${canonicalJson({
          ...metadata,
          'publisher': publisher,
          'signingKeyId': signingKeyId,
          'packageDigest': digest
        })}';
    return _verifySignature(
      publisher: publisher,
      signingKeyId: signingKeyId,
      signature: signature,
      message: utf8.encode(payload),
    );
  }

  Future<bool> _verifySignature({
    required String publisher,
    required String signingKeyId,
    required String signature,
    required List<int> message,
  }) async {
    final encodedKey = trustedPublicKeys[publisher]?[signingKeyId];
    if (encodedKey == null || signature.isEmpty) return false;
    try {
      final publicBytes = base64.decode(encodedKey);
      final signatureBytes = base64.decode(signature);
      if (publicBytes.length != 32 || signatureBytes.length != 64) return false;
      return await Ed25519().verify(
        message,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }

  void requirePermissions(
      Iterable<WorkerPermission> declared, Iterable<WorkerPermission> allowed) {
    final allow = allowed.toSet();
    if (!declared.every(allow.contains)) {
      throw StateError('worker requested a denied permission');
    }
  }
}

String canonicalJson(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort(
          (left, right) => left.key.toString().compareTo(right.key.toString()));
    return '{${entries.map((entry) => '${jsonEncode(entry.key.toString())}:${canonicalJson(entry.value)}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  return jsonEncode(value);
}

String redactSecrets(String value, Iterable<String> secrets) {
  var result = value;
  for (final secret in secrets.where((secret) => secret.isNotEmpty)) {
    result = result.replaceAll(secret, '[REDACTED]');
  }
  return result;
}
