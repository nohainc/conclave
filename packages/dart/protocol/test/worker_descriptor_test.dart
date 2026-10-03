import 'package:conclave_protocol/worker_descriptor.dart';
import 'package:test/test.dart';

void main() {
  test('deserializes a Cloud-defined Claude Worker generically', () {
    final descriptor = WorkerDescriptor.fromJson({
      'workerTypeId': 'claude',
      'displayName': 'Claude',
      'description': 'Claude Code CLI integration',
      'engineFamily': 'cli',
      'capabilities': ['text', 'workstream_read', 'workstream_write'],
      'profileDefinitionId': 'claude-code',
      'providerToolName': 'claude',
      'releaseStage': 'beta',
      'visibilityState': 'visible',
      'sortOrder': 30,
    });

    expect(descriptor.workerTypeId, 'claude');
    expect(descriptor.displayName, 'Claude');
    expect(descriptor.profileDefinitionId, 'claude-code');
    expect(descriptor.providerToolName, 'claude');
  });

  test('does not accept local inventory fields on a descriptor', () {
    expect(
      () => WorkerDescriptor.fromJson({
        'workerTypeId': 'claude',
        'displayName': 'Claude',
        'description': '',
        'engineFamily': 'cli',
        'capabilities': ['text'],
        'profileDefinitionId': 'claude-code',
        'providerToolName': 'claude',
        'releaseStage': 'stable',
        'visibilityState': 'visible',
        'sortOrder': 30,
        'readinessState': 'ready',
      }),
      throwsFormatException,
    );
  });
}
