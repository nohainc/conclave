import 'package:conclave_codex_worker/codex_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares v4 protocol, private credential policy, and concurrency', () {
    expect(codexWorkerManifest['protocolVersion'], '4.0');
    expect(codexWorkerManifest['credentialSharingPolicy'], 'private_only');
    expect(codexWorkerManifest['credentialRequirements'], isNotEmpty);
    expect(codexWorkerManifest['sessionModes'], contains('reuse_session'));
    expect(codexWorkerManifest['concurrencyModel'], isA<Map>());
    expect(codexWorkerManifest['digest'], startsWith('sha256:'));
  });
}
