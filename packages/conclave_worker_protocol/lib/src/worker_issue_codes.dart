/// Stable, provider-neutral issue codes carried by Worker protocol frames.
abstract final class WorkerIssueCode {
  static const malformedFrame = 'malformed_frame';
  static const protocolVersionUnsupported = 'protocol_version_unsupported';
  static const workerTypeMismatch = 'worker_type_mismatch';
  static const workerVersionMismatch = 'worker_version_mismatch';
  static const stateSchemaIncompatible = 'state_schema_incompatible';
  static const deadlineExceeded = 'deadline_exceeded';
  static const cancelled = 'cancelled';
  static const providerToolUnavailable = 'provider_tool_unavailable';
  static const providerAuthenticationRequired =
      'provider_authentication_required';
  static const permissionDenied = 'permission_denied';
  static const providerFailure = 'provider_failure';
  static const workerInternalFailure = 'worker_internal_failure';

  static const known = {
    malformedFrame,
    protocolVersionUnsupported,
    workerTypeMismatch,
    workerVersionMismatch,
    stateSchemaIncompatible,
    deadlineExceeded,
    cancelled,
    providerToolUnavailable,
    providerAuthenticationRequired,
    permissionDenied,
    providerFailure,
    workerInternalFailure,
  };

  static bool isKnown(String value) => known.contains(value);
}
