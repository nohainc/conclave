import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_chatgpt_worker/chatgpt_worker_service.dart';

const workerVersion = String.fromEnvironment(
  'WORKER_VERSION',
  defaultValue: '0.1.0',
);

Future<void> main() {
  final service = ChatGptWorkerService();
  return WorkerRuntime(
    identity: const WorkerIdentity(
      workerTypeId: 'chatgpt',
      workerVersion: workerVersion,
      capabilities: ['initialize', 'probe', 'execute', 'durable_session'],
    ),
    onProbe: service.probe,
    onExecute: service.execute,
  ).run();
}
