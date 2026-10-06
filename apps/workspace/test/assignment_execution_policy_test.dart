import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('read-only assignments require Profile read-only capability', () {
    for (final identity in ['chatgpt', 'gemini', 'future-worker']) {
      final readOnly = <String, Object?>{
        'readOnly': true,
        'workerTypeId': identity
      };
      expect(
          profileAllowsAssignment(readOnly, ['text', 'local_file']), isFalse);
      expect(profileAllowsAssignment(readOnly, ['workstream_read']), isTrue);
      expect(profileAllowsAssignment({'readOnly': false}, ['text']), isTrue);
    }
  });
  test('Cloud permissions choose the generic provider policy', () {
    expect(
        assignmentExecutionPolicy({
          'readOnly': true,
          'executionClass': 'stateless_read',
        }),
        WorkerExecutionPolicy.providerDefault);
    expect(
        assignmentExecutionPolicy({
          'readOnly': false,
          'executionClass': 'stateful_workstream',
        }),
        WorkerExecutionPolicy.restricted);
    // Both existing read-only signals independently preserve the restriction.
    expect(
        assignmentExecutionPolicy({
          'readOnly': true,
          'executionClass': 'stateful_workstream',
        }),
        WorkerExecutionPolicy.providerDefault);
    expect(
        assignmentExecutionPolicy({
          'readOnly': false,
          'executionClass': 'stateless_read',
        }),
        WorkerExecutionPolicy.providerDefault);
  });

  test('UI labels, step names and provider identity cannot choose permissions',
      () {
    for (final label in ['Chat', 'Work', 'Direct', 'unknown']) {
      for (final provider in ['chatgpt', 'gemini', 'dynamic-worker']) {
        final metadata = <String, Object?>{
          'workflowName': label,
          'role': 'chat',
          'workerTypeId': provider,
        };
        expect(
            assignmentExecutionPolicy({
              ...metadata,
              'readOnly': false,
              'executionClass': 'stateful_workstream',
            }),
            WorkerExecutionPolicy.restricted);
        expect(
            assignmentExecutionPolicy({
              ...metadata,
              'readOnly': true,
              'executionClass': 'stateless_read',
            }),
            WorkerExecutionPolicy.providerDefault);
      }
    }
  });
}
