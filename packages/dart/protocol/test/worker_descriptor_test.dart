import 'package:syntila_protocol/worker_descriptor.dart';
import 'package:test/test.dart';

void main() {
  test('deserializes a Cloud-defined Claude Worker generically', () {
    final descriptor = WorkerDescriptor.fromJson({
      'workerTypeId': 'claude',
      'displayName': 'Claude',
      'description': 'Claude Code CLI integration',
      'engineFamily': 'cli',
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

  test('deserializes the V9 Cloud catalog lifecycle field', () {
    final descriptor = WorkerDescriptor.fromJson({
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'description': 'Logical Worker implemented by approved local tools.',
      'engineFamily': 'cli',
      'profileDefinitionId': 'chatgpt-codex',
      'providerToolName': 'Codex CLI',
      'lifecycleState': 'active',
      'visibilityState': 'visible',
      'sortOrder': 10,
    });

    expect(descriptor.workerTypeId, 'chatgpt');
    expect(descriptor.profileDefinitionId, 'chatgpt-codex');
    expect(descriptor.releaseStage, 'stable');
  });

  test('deserializes the complete V9 Cloud catalog response', () {
    final descriptor = WorkerDescriptor.fromJson({
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'description': 'Logical Worker implemented by approved local tools.',
      'engineFamily': 'cli',
      'profileDefinitionId': 'chatgpt-codex',
      'providerToolName': 'codex',
      'lifecycleState': 'active',
      'visibilityState': 'visible',
      'sortOrder': 10,
      'currentRevision': 1,
      'currentDigest':
          '5086e28eac72607adcded224f051f1f4c080771455d2395f9f2302f121e49fca',
      'currentUpdatedAt': '2026-10-12T20:37:32.103Z',
    });

    expect(descriptor.workerTypeId, 'chatgpt');
    expect(descriptor.releaseStage, 'stable');
  });
}
