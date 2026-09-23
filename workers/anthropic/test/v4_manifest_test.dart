import 'package:conclave_anthropic_worker/anthropic_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares v4 API credential profile and usage-capable execution', () {
    expect(anthropicWorkerManifest['protocolVersion'], '4.0');
    expect(anthropicWorkerManifest['credentialSharingPolicy'],
        'workspace_capable');
    expect(anthropicWorkerManifest['credentialRequirements'], isNotEmpty);
    expect(anthropicWorkerManifest['concurrencyModel'], isA<Map>());
    expect(anthropicWorkerManifest['digest'], startsWith('sha256:'));
  });
}
