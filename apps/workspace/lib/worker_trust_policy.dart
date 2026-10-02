import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Public verification roots shipped with Workspace. Values are base64 raw
/// Ed25519 public keys, keyed by publisher and explicit key ID. This class
/// never accepts signing secrets.
class WorkerTrustPolicy {
  WorkerTrustPolicy({
    Map<String, Map<String, String>> trustedPublicKeys = const {},
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

  Future<bool> verifyWorkspaceRelease({
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
