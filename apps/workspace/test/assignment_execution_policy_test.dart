import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_workspace/worker_executor.dart';
import 'package:conclave_workspace/cloud_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
          'executionClass': 'stateful_thread',
        }),
        WorkerExecutionPolicy.restricted);
    // Both existing read-only signals independently preserve the restriction.
    expect(
        assignmentExecutionPolicy({
          'readOnly': true,
          'executionClass': 'stateful_thread',
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
              'executionClass': 'stateful_thread',
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

  test('full access requires persisted local authorization', () {
    final payload = <String, Object?>{
      'executionPolicy': 'full_access',
      'executionClass': 'stateful_thread',
      'readOnly': false,
    };
    expect(
      () => assignmentExecutionPolicy(payload),
      throwsA(isA<AssignmentExecutionFailure>()),
    );
    expect(
      assignmentExecutionPolicy(payload, fullAccessAuthorized: true),
      WorkerExecutionPolicy.fullAccess,
    );
    expect(
      assignmentExecutionPolicy({
        'executionClass': 'stateful_thread',
      }, fullAccessAuthorized: true),
      WorkerExecutionPolicy.fullAccess,
    );
    expect(
      assignmentExecutionPolicy({
        'executionClass': 'stateless_read',
        'readOnly': false,
      }, fullAccessAuthorized: true),
      WorkerExecutionPolicy.fullAccess,
    );
    expect(
      assignmentExecutionPolicy({
        'executionClass': 'stateless_read',
        'readOnly': true,
      }, fullAccessAuthorized: true),
      WorkerExecutionPolicy.providerDefault,
    );
  });

  test('unknown explicit policies are rejected', () {
    expect(
      () => assignmentExecutionPolicy({'executionPolicy': 'unrestricted'}),
      throwsA(isA<AssignmentExecutionFailure>()),
    );
  });
}
