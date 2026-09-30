import 'worker_logger.dart';

class WorkerDiagnosticCollector {
  const WorkerDiagnosticCollector({this.maxCharacters = 8192});

  final int maxCharacters;

  String capture(String value) {
    final safe = WorkerRedactor.redact(value);
    return safe.length <= maxCharacters
        ? safe
        : safe.substring(0, maxCharacters);
  }
}
