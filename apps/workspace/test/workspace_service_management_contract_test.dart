import 'package:conclave_workspace/workspace_background_service.dart';
import 'package:test/test.dart';

void main() {
  test('unsupported host reports status without pretending registration',
      () async {
    const manager = UnsupportedWorkspaceServiceManager();
    final status = await manager.status();

    expect(status.supported, isFalse);
    expect(status.registration,
        WorkspaceBackgroundServiceRegistration.unsupported);
    await expectLater(manager.register(), throwsA(isA<UnsupportedError>()));
    await expectLater(manager.unregister(), throwsA(isA<UnsupportedError>()));
    await expectLater(manager.openSettings(), throwsA(isA<UnsupportedError>()));
  });
}
