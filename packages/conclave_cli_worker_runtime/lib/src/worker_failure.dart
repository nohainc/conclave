import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

/// A safe, stable failure that may be returned over Local Worker Protocol.
class WorkerFailure implements Exception {
  WorkerFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.diagnostics,
  }) {
    if (!WorkerIssueCode.isKnown(code)) {
      throw ArgumentError.value(code, 'code', 'unknown Worker issue code');
    }
  }

  final String code;
  final String message;
  final bool retryable;
  final String? diagnostics;
}
