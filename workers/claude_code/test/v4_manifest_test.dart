import 'package:conclave_claude_code_worker/claude_code_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('declares v4 protocol and isolated CLI sessions', () {
    expect(claudeCodeWorkerManifest['protocolVersion'], '4.0');
    expect(claudeCodeWorkerManifest['credentialSharingPolicy'], 'private_only');
    expect(claudeCodeWorkerManifest['sessionModes'],
        contains('isolated_workspace'));
    expect(claudeCodeWorkerManifest['concurrencyModel'], isA<Map>());
    expect(claudeCodeWorkerManifest['digest'], startsWith('sha256:'));
  });
}
