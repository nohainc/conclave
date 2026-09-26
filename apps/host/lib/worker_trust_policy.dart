import 'dart:convert';
import 'package:crypto/crypto.dart';

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

WorkerPermission parseWorkerPermission(String value) {
  return switch (value) {
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
}

Set<WorkerPermission> parseConfiguredWorkerPermissions(String? configured) {
  if (configured == null || configured.trim().isEmpty) return {};
  return configured
      .split(',')
      .map((permission) => permission.trim())
      .where((permission) => permission.isNotEmpty)
      .map(parseWorkerPermission)
      .toSet();
}

class WorkerTrustPolicy {
  const WorkerTrustPolicy({
    this.trustedSecrets = const {},
    this.trustedKeys = const {},
    this.revokedDigests = const {},
    this.revokedPublishers = const {},
    this.revokedKeyIds = const {},
  });
  final Map<String, String> trustedSecrets;
  final Map<String, Map<String, String>> trustedKeys;
  final Set<String> revokedDigests;
  final Set<String> revokedPublishers;
  final Set<String> revokedKeyIds;

  String sign(String publisher, String digest, {String? keyId}) {
    final keySet = trustedKeys[publisher];
    if (keySet != null && keySet.isNotEmpty) {
      final resolvedKeyId = keyId ?? (keySet.keys.toList()..sort()).first;
      final secret = keySet[resolvedKeyId];
      if (secret == null || revokedKeyIds.contains(resolvedKeyId)) {
        throw StateError('publisher key is not trusted');
      }
      return 'sig_${resolvedKeyId}_${_mac(secret, digest)}';
    }
    final secret = trustedSecrets[publisher];
    if (secret == null) throw StateError('publisher is not trusted');
    return 'sig_${_mac(secret, digest)}';
  }

  bool verify({
    required String publisher,
    required String digest,
    required String signature,
  }) {
    if (revokedDigests.contains(digest) ||
        revokedPublishers.contains(publisher)) {
      return false;
    }
    final legacy = trustedSecrets[publisher];
    if (legacy != null &&
        (signature == 'sig_${_mac(legacy, digest)}' ||
            signature == 'sig_pkg_${_mac(legacy, digest)}')) {
      return true;
    }
    final keySet = trustedKeys[publisher];
    if (keySet == null) return false;
    return keySet.entries.any((entry) =>
        !revokedKeyIds.contains(entry.key) &&
        (signature == 'sig_${entry.key}_${_mac(entry.value, digest)}' ||
            signature == 'sig_pkg_${entry.key}_${_mac(entry.value, digest)}'));
  }

  /// Signs the package file-tree digest together with every manifest field
  /// except `signature`. V7 manifests control executable paths, permissions,
  /// and credentials, so signing only the package files would allow those
  /// declarations to be changed independently of the signature.
  String signAdapterManifest(
    String publisher,
    String digest,
    Map<String, Object?> manifest, {
    String? keyId,
  }) {
    final payload = _adapterManifestPayload(digest, manifest);
    final keySet = trustedKeys[publisher];
    if (keySet != null && keySet.isNotEmpty) {
      final resolvedKeyId = keyId ?? (keySet.keys.toList()..sort()).first;
      final secret = keySet[resolvedKeyId];
      if (secret == null || revokedKeyIds.contains(resolvedKeyId)) {
        throw StateError('publisher key is not trusted');
      }
      return 'sig_${resolvedKeyId}_m_${_mac(secret, payload)}';
    }
    final secret = trustedSecrets[publisher];
    if (secret == null) throw StateError('publisher is not trusted');
    return 'sig_m_${_mac(secret, payload)}';
  }

  bool verifyAdapterManifest({
    required String publisher,
    required String digest,
    required String signature,
    required Map<String, Object?> manifest,
  }) {
    if (revokedDigests.contains(digest) ||
        revokedPublishers.contains(publisher)) {
      return false;
    }
    final payload = _adapterManifestPayload(digest, manifest);
    final legacy = trustedSecrets[publisher];
    if (legacy != null && signature == 'sig_m_${_mac(legacy, payload)}') {
      return true;
    }
    final keySet = trustedKeys[publisher];
    if (keySet == null) return false;
    return keySet.entries.any((entry) =>
        !revokedKeyIds.contains(entry.key) &&
        signature == 'sig_${entry.key}_m_${_mac(entry.value, payload)}');
  }

  String _mac(String secret, String digest) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(digest)).toString();

  void requirePermissions(
      Iterable<WorkerPermission> declared, Iterable<WorkerPermission> allowed) {
    final allow = allowed.toSet();
    if (!declared.every(allow.contains)) {
      throw StateError('worker requested a denied permission');
    }
  }
}

String _adapterManifestPayload(String digest, Map<String, Object?> manifest) {
  final unsigned = Map<String, Object?>.from(manifest)..remove('signature');
  return '$digest\n${_canonicalJson(unsigned)}';
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

String redactSecrets(String value, Iterable<String> secrets) {
  var result = value;
  for (final secret in secrets.where((secret) => secret.isNotEmpty)) {
    result = result.replaceAll(secret, '[REDACTED]');
  }
  return result;
}
