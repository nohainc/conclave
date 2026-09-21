import 'dart:convert';
import 'package:crypto/crypto.dart';

enum PluginPermission {
  readWorkspace,
  writeWorkspace,
  shell,
  network,
  credentials
}

class PluginTrustPolicy {
  const PluginTrustPolicy(
      {required this.trustedSecrets, this.revokedDigests = const {}});
  final Map<String, String> trustedSecrets;
  final Set<String> revokedDigests;

  String sign(String publisher, String digest) {
    final secret = trustedSecrets[publisher];
    if (secret == null) throw StateError('publisher is not trusted');
    final mac = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(digest));
    return 'sig_${mac.toString()}';
  }

  bool verify(
      {required String publisher,
      required String digest,
      required String signature}) {
    if (revokedDigests.contains(digest)) return false;
    return sign(publisher, digest) == signature;
  }

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
