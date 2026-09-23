import 'package:conclave_forge_worker/forge_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares Forge as a v4 Worker package', () {
    expect(forgeWorkerManifest['workerId'], 'conclave.forge');
    expect(forgeWorkerManifest['protocolVersion'], '4.0');
    expect(forgeWorkerManifest['sessionModes'], contains('isolated_workspace'));
    expect(forgeWorkerManifest['concurrencyModel'], isA<Map>());
    expect(forgeWorkerManifest['digest'], startsWith('sha256:'));
  });
}
