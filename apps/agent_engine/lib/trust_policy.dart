import 'dart:convert';
import 'package:crypto/crypto.dart';

enum PluginPermission {
  readWorkspace,
  writeWorkspace,
  shell,
  network,
  credentials
}

extension PluginPermissionWire on PluginPermission {
  String get wireName => switch (this) {
        PluginPermission.readWorkspace => 'workspace:read',
        PluginPermission.writeWorkspace => 'workspace:write',
        PluginPermission.shell => 'shell:execute',
        PluginPermission.network => 'network:outbound',
        PluginPermission.credentials => 'credentials:read',
      };
}

PluginPermission parsePluginPermission(String value) {
  return switch (value) {
    'readWorkspace' || 'workspace:read' => PluginPermission.readWorkspace,
    'writeWorkspace' || 'workspace:write' => PluginPermission.writeWorkspace,
    'shell' || 'shell:execute' => PluginPermission.shell,
    'network' || 'network:outbound' => PluginPermission.network,
    'credentials' || 'credentials:read' => PluginPermission.credentials,
    _ => throw StateError('unknown plugin permission: $value'),
  };
}

Set<PluginPermission> parseConfiguredPluginPermissions(String? configured) {
  if (configured == null || configured.trim().isEmpty) return {};
  return configured
      .split(',')
      .map((permission) => permission.trim())
      .where((permission) => permission.isNotEmpty)
      .map(parsePluginPermission)
      .toSet();
}

class PluginTrustPolicy {
  const PluginTrustPolicy({
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
    if (legacy != null && signature == 'sig_${_mac(legacy, digest)}') {
      return true;
    }
    final keySet = trustedKeys[publisher];
    if (keySet == null) return false;
    return keySet.entries.any((entry) =>
        !revokedKeyIds.contains(entry.key) &&
        signature == 'sig_${entry.key}_${_mac(entry.value, digest)}');
  }

  String _mac(String secret, String digest) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(digest)).toString();

  void requirePermissions(
      Iterable<PluginPermission> declared, Iterable<PluginPermission> allowed) {
    final allow = allowed.toSet();
    if (!declared.every(allow.contains)) {
      throw StateError('plugin requested a denied permission');
    }
  }
}

String redactSecrets(String value, Iterable<String> secrets) {
  var result = value;
  for (final secret in secrets.where((secret) => secret.isNotEmpty)) {
    result = result.replaceAll(secret, '[REDACTED]');
  }
  return result;
}
