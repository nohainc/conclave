import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_service_state.dart';
import 'package:test/test.dart';

void main() {
  test('Cloud state is independent from a running service process', () {
    expect(
      WorkspaceServiceState.cloudStateFor(
        configured: true,
        authenticated: true,
        stage: WorkspaceConnectionStage.offline,
      ),
      WorkspaceServiceCloudState.disconnected,
    );
    expect(
      WorkspaceServiceState.cloudStateFor(
        configured: false,
        authenticated: false,
        stage: null,
      ),
      WorkspaceServiceCloudState.notConfigured,
    );
    expect(
      WorkspaceServiceState.cloudStateFor(
        configured: true,
        authenticated: false,
        stage: WorkspaceConnectionStage.offline,
      ),
      WorkspaceServiceCloudState.authenticationRequired,
    );
  });

  test('runtime state records process and Cloud status and releases its lock',
      () async {
    final directory = await Directory.systemTemp.createTemp('workspace-svc-');
    addTearDown(() => directory.delete(recursive: true));
    final workRoot = await Directory.systemTemp.createTemp('workspace-work-');
    addTearDown(() => workRoot.delete(recursive: true));
    final first = Workspace(
        config: WorkspaceConfig(
      dataDirectory: directory,
      installationId: 'install_test-identity',
      workRootPath: workRoot.path,
    ));
    final second = Workspace(
        config: WorkspaceConfig(
      dataDirectory: directory,
      installationId: 'install_test-identity',
      workRootPath: workRoot.path,
    ));

    await first.start();
    final stateFile = File('${directory.path}/workspace-state.json');
    var state = jsonDecode(await stateFile.readAsString()) as Map;
    expect(state['processState'], 'ready');
    expect(state['cloudState'], 'notConfigured');
    expect(state['installationId'], 'install_test-identity');

    await first.stop();
    state = jsonDecode(await stateFile.readAsString()) as Map;
    expect(state['processState'], 'stopped');

    // OS advisory locks are released when their owner closes/exits. The lock
    // file remains the stable per-installation lock target.
    await second.start();
    await second.stop();
  });
}
