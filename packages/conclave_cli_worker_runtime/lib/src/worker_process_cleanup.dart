import 'dart:async';
import 'dart:io';

/// Direct-child cleanup primitive. OS-specific descendant supervision is added
/// by the Worker process supervisor integration.
class WorkerProcessCleanup {
  const WorkerProcessCleanup();

  Future<int> terminate(
    Process process, {
    Duration grace = const Duration(seconds: 2),
  }) async {
    process.kill(ProcessSignal.sigterm);
    try {
      return await process.exitCode.timeout(grace);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    }
  }
}
