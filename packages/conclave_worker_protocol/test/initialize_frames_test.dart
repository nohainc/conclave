import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('initialize request and result round-trip as protocol 3.0 frames', () {
    final request = InitializeRequest(
      requestId: 'init-1',
      workerTypeId: 'chatgpt',
      expectedWorkerVersion: '0.1.0',
    );
    expect(decodeWorkerFrame(request.encode()).toJson(), request.toJson());

    final result = InitializeResult(
      requestId: request.requestId,
      workerTypeId: 'chatgpt',
      workerVersion: '0.1.0',
      stateSchemaVersion: 1,
      capabilities: const ['initialize'],
    );
    expect(decodeWorkerFrame(result.encode()).toJson(), result.toJson());
  });

  test('negotiates the highest common protocol version', () {
    expect(
      negotiateProtocolVersion(
        workspaceVersions: const ['2.0', '3.0'],
        workerVersions: const ['2.0', '3.0'],
      ),
      '3.0',
    );
    expect(
      negotiateProtocolVersion(
        workspaceVersions: const ['2.6'],
        workerVersions: const ['2.6'],
      ),
      isNull,
    );
  });

  test('rejects an oversized capability list', () {
    expect(
      () => InitializeResult(
        requestId: 'init-1',
        workerTypeId: 'chatgpt',
        workerVersion: '0.1.0',
        stateSchemaVersion: 1,
        capabilities: List.filled(
          WorkerProtocolLimits.maxCapabilities + 1,
          'x',
        ),
      ),
      throwsFormatException,
    );
  });
}
