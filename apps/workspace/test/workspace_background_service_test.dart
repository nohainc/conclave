import 'package:conclave_workspace/workspace_background_service.dart';
import 'package:test/test.dart';

void main() {
  test('maps macOS registration and approval states', () {
    expect(
      WorkspaceBackgroundServiceStatus.fromNative(const {
        'supported': true,
        'registration': 'registered',
        'helperPresent': true,
        'plistPresent': true,
        'running': false,
      }).registration,
      WorkspaceBackgroundServiceRegistration.registered,
    );
    expect(
      WorkspaceBackgroundServiceStatus.fromNative(const {
        'supported': true,
        'registration': 'approvalRequired',
        'helperPresent': true,
        'plistPresent': true,
      }).registration,
      WorkspaceBackgroundServiceRegistration.approvalRequired,
    );
  });

  test('missing helper and unsupported OS remain explicit', () {
    final missing = WorkspaceBackgroundServiceStatus.fromNative(const {
      'supported': true,
      'registration': 'serviceMissing',
      'helperPresent': false,
      'plistPresent': true,
    });
    expect(missing.registration,
        WorkspaceBackgroundServiceRegistration.serviceMissing);
    expect(missing.helperPresent, isFalse);

    final unsupported = WorkspaceBackgroundServiceStatus.fromNative(const {
      'supported': false,
      'registration': 'unsupported',
    });
    expect(unsupported.registration,
        WorkspaceBackgroundServiceRegistration.unsupported);
  });
}
