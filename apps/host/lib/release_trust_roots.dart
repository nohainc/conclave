import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'worker_trust_policy.dart';

/// Build-injected public release roots. Empty or invalid configuration fails
/// closed because no signing key is trusted.
Map<String, Map<String, String>> workspaceReleaseTrustRoots() {
  const configured = String.fromEnvironment(
    'CONCLAVE_RELEASE_TRUST_KEYS_JSON',
    defaultValue: '{}',
  );
  try {
    final value = jsonDecode(configured);
    if (value is! Map) return const {};
    return {
      for (final publisher in value.entries)
        if (publisher.key is String && publisher.value is Map)
          publisher.key as String: {
            for (final key in (publisher.value as Map).entries)
              if (key.key is String && key.value is String)
                key.key as String: key.value as String,
          },
    };
  } on Object {
    return const {};
  }
}

WorkerTrustPolicy workspaceReleaseTrustPolicy() => WorkerTrustPolicy(
      trustedPublicKeys: workspaceReleaseTrustRoots(),
      allowUnsignedDevelopmentReleases: kDebugMode &&
          const bool.fromEnvironment(
            'CONCLAVE_ENABLE_UNSIGNED_DEVELOPMENT_WORKERS',
            defaultValue: false,
          ),
    );
