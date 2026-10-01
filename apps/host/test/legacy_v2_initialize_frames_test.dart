import 'package:conclave_host/legacy_v2_initialize_frames.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('migration-only initialize result round-trips within strict bounds', () {
    final response = LegacyV2InitializeResult(
      requestId: 'init-1',
      workerTypeId: 'chatgpt',
      workerVersion: '1.2.3',
      stateSchemaVersion: 1,
      capabilities: const ['execute', 'passive_probe'],
    );

    final decoded = LegacyV2InitializeResult.fromJson(response.toJson());

    expect(decoded.toJson(), response.toJson());
  });

  test('migration-only initialize result rejects unknown fields', () {
    expect(
      () => LegacyV2InitializeResult.fromJson({
        'type': 'initialize.result',
        'protocolVersion': localWorkerProtocolVersion,
        'requestId': 'init-1',
        'workerTypeId': 'chatgpt',
        'workerVersion': '1.2.3',
        'stateSchemaVersion': 1,
        'capabilities': <String>['execute'],
        'unexpected': true,
      }),
      throwsFormatException,
    );
  });
}
