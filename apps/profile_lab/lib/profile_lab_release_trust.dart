import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

/// Production public trust roots injected by the Profile Lab build pipeline.
/// Empty or invalid values fail closed and leave the AI model catalog empty.
WorkerTrustPolicy profileLabReleaseTrustPolicy() {
  const configured = String.fromEnvironment(
    'CONCLAVE_RELEASE_TRUST_KEYS_JSON',
    defaultValue: '{}',
  );
  return ReleaseTrustRoots.createPolicy(configured);
}
