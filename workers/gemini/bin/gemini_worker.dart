import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_gemini_worker/gemini_worker_service.dart';

const workerVersion = String.fromEnvironment(
  'WORKER_VERSION',
  defaultValue: '0.1.0',
);

Future<void> main() {
  final service = GeminiWorkerService();
  return WorkerRuntime(
    identity: const WorkerIdentity(
      workerTypeId: 'gemini',
      workerVersion: workerVersion,
      capabilities: [
        'initialize',
        'probe',
        'execute',
        'durable_session',
        'authorized_context_read',
        'workstream_write',
        'text',
        'local_file',
      ],
    ),
    onProbe: service.probe,
    onExecute: service.execute,
  ).run();
}
