/// Conservative protocol limits. These are wire limits, not provider limits.
abstract final class WorkerProtocolLimits {
  static const maxFrameBytes = 1024 * 1024;
  static const maxRequestIdLength = 128;
  static const maxWorkerTypeIdLength = 64;
  static const maxWorkerVersionLength = 64;
  static const maxEngineVersionLength = 64;
  static const maxProfileDefinitionIdLength = 128;
  static const maxProfileReleaseVersionLength = 64;
  static const maxProfileSchemaVersion = 0x7fffffff;
  static const maxProfileDigestLength = 64;
  static const maxStateSchemaVersion = 0x7fffffff;
  static const maxCapabilities = 64;
  static const maxCapabilityLength = 128;
  static const maxPromptBytes = 512 * 1024;
  static const maxOutputBytes = 768 * 1024;
  static const maxModelLength = 128;
  static const maxSessionKeyLength = 256;
  static const maxTimeoutMs = 24 * 60 * 60 * 1000;
  static const maxProbeTimeoutMs = 30 * 1000;
  static const maxProbeChecks = 32;
  static const maxCheckCodeLength = 64;
  static const maxCheckMessageLength = 1024;
  static const maxProviderToolNameLength = 128;
  static const maxProviderToolVersionLength = 64;
  static const maxDiagnosticLength = 8192;
  static const maxProgressMessageLength = 2048;
  static const maxErrorMessageLength = 2048;
  static const maxArtifacts = 64;
  static const maxArtifactIdLength = 256;
}
