import 'package:conclave_workspace/runtime_capabilities.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> assignmentPayload({
    List<String> permissions = const ['repository:read'],
    Map<String, Object?>? input,
    Map<String, Object?>? networkPolicy,
  }) =>
      {
        'spaceId': 'space-1',
        'executionWorkspaceId': 'workspace-1',
        'permissionSnapshot': {
          'spaceId': 'space-1',
          'workspaceId': 'workspace-1',
          'grantId': 'grant-1',
          'requesterUserId': 'user-1',
          'permissions': permissions,
          'networkPolicy': networkPolicy ?? {'mode': 'deny_all'},
        },
        'input': input ?? <String, Object?>{},
      };

  test('rejects worker-controlled alternate working directories', () {
    expect(
      () => validateAssignmentScope(
        assignmentPayload(input: {'workingDirectory': '/etc'}),
        localWorkerPermissions: {'repository:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('rejects undeclared network and credential material', () {
    expect(
      () => validateAssignmentScope(
        assignmentPayload(
          permissions: const ['network:use'],
          networkPolicy: {'mode': 'deny_all'},
        ),
        localWorkerPermissions: {'network:use'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => validateAssignmentScope(
        assignmentPayload(input: {'apiKey': 'should-never-cross-runtime'}),
        localWorkerPermissions: {'repository:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('permits declared permissions within the assignment snapshot', () {
    expect(
      () => validateAssignmentScope(
        assignmentPayload(
          permissions: const ['repository:read', 'shell:execute'],
        ),
        localWorkerPermissions: {'repository:read', 'shell:execute'},
      ),
      returnsNormally,
    );
  });

  test('rejects system administration even when locally allowed', () {
    expect(
      () => validateAssignmentScope(
        assignmentPayload(permissions: const ['system:admin']),
        localWorkerPermissions: const {'system:admin'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('rejects old aliases and mismatched permission copies', () {
    expect(
      () => validateAssignmentScope(
        assignmentPayload(permissions: const ['workspace:read']),
        localWorkerPermissions: {'workspace:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    final mismatched = assignmentPayload();
    mismatched['permissions'] = ['repository:write'];
    expect(
      () => validateAssignmentScope(
        mismatched,
        localWorkerPermissions: {'repository:read', 'repository:write'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });
}
