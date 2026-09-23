import 'package:conclave_openai_worker/openai_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares v4 API credential profile and usage-capable execution', () {
    expect(openAiWorkerManifest['protocolVersion'], '4.0');
    expect(
        openAiWorkerManifest['credentialSharingPolicy'], 'workspace_capable');
    expect(openAiWorkerManifest['credentialRequirements'], isNotEmpty);
    expect(openAiWorkerManifest['concurrencyModel'], isA<Map>());
    expect(openAiWorkerManifest['digest'], startsWith('sha256:'));
  });
}
