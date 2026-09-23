import 'package:conclave_echo_worker/echo_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares the v4 Worker contract and safe local execution policy', () {
    expect(echoWorkerManifest['workerId'], 'conclave.echo');
    expect(echoWorkerManifest['protocolVersion'], '4.0');
    expect(echoWorkerManifest['credentialRequirements'], isNotEmpty);
    expect(echoWorkerManifest['sessionModes'], contains('stateless'));
    expect(echoWorkerManifest['concurrencyModel'], isA<Map>());
    expect(echoWorkerManifest['digest'], startsWith('sha256:'));
    expect(echoWorkerManifest['signature'], isNotEmpty);
  });
}
