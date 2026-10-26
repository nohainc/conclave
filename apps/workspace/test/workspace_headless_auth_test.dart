import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/desktop_auth.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_headless_auth.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:test/test.dart';

class _Credentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Auth extends DesktopAuthClient {
  _Auth() : super(cloudUrl: 'https://example.test');
  final approval = Completer<DesktopHumanSession>();
  WorkspaceOwnership ownership =
      const WorkspaceOwnership(state: WorkspaceOwnershipState.unbound);
  bool cancelled = false;
  @override
  Future<DesktopAuthIntent> createIntent() async => DesktopAuthIntent(
      intentId: 'intent',
      pollToken: 'private-poll-token',
      verificationUrl:
          Uri.parse('https://example.test/approve?intentId=intent'),
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      pollIntervalMs: 1000);
  @override
  Future<DesktopHumanSession> waitForApprovalAndClaim(DesktopAuthIntent intent,
          {bool Function()? isCancelled}) =>
      approval.future;
  @override
  Future<void> validateSession(DesktopHumanSession session) async {}
  @override
  Future<WorkspaceOwnership> checkWorkspaceOwnership(
          {required DesktopHumanSession session,
          required String installationId,
          String? workspaceId,
          String? runtimeId}) async =>
      ownership;
  @override
  Future<void> cancelIntent(DesktopAuthIntent intent) async {
    cancelled = true;
  }
}

DesktopHumanSession session() => DesktopHumanSession(
    credential: 'private-human-token',
    sessionId: 'session',
    userId: 'user',
    displayName: 'User',
    email: 'u@example.test',
    expiresAt: DateTime.now().add(const Duration(hours: 1)));

Future<Map<String, Object?>> terminal(WorkspaceHeadlessAuth auth) async {
  for (var i = 0; i < 200; i++) {
    final state = auth.status();
    if (state['phase'] != 'pending') return state;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Sign-in did not complete');
}

void main() {
  late Directory root;
  late _Credentials credentials;
  late _Auth client;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('headless-auth-');
    credentials = _Credentials();
    client = _Auth();
  });
  tearDown(() async {
    client.close();
    await root.delete(recursive: true);
  });

  test('fresh approval registers once, stores secrets privately and reloads',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var registrations = 0;
    server.listen((request) async {
      expect(request.uri.path, '/api/workspace-runtime/register');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer private-human-token');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['installationId'],
          await InstallationIdentityStore(root).getOrCreate());
      registrations++;
      request.response.statusCode = 201;
      request.response.write(jsonEncode({
        'workspaceRuntimeId': 'runtime',
        'workspaceId': 'workspace',
        'workspaceName': 'Server',
        'ownerUserId': 'user',
        'runtimeCredential': 'private-runtime-token'
      }));
      await request.response.close();
    });
    var reloads = 0;
    final auth = WorkspaceHeadlessAuth(
        dataDirectory: root,
        cloudUrl: 'http://127.0.0.1:${server.port}',
        credentialStore: credentials,
        reloadRuntime: () async {
          reloads++;
        },
        clientFactory: (_) => client);
    final pending = await auth.start();
    expect(pending['verificationUrl'], contains('/approve'));
    expect(jsonEncode(pending), isNot(contains('private-poll-token')));
    await expectLater(
        auth.start(), throwsA(isA<WorkspaceManagerProtocolException>()));
    client.approval.complete(session());
    expect((await terminal(auth))['phase'], 'complete');
    expect(registrations, 1);
    expect(reloads, 1);
    expect(credentials.values['runtime'], 'private-runtime-token');
    expect(credentials.values[desktopHumanCredentialKey],
        contains('private-human-token'));
    expect(jsonEncode(auth.status()), isNot(contains('private-')));
    expect(
        WorkspaceRegistrationStore(root).readSync()!.workspaceId, 'workspace');
    await auth.close();
  });

  test('cross-account and ambiguous ownership cannot overwrite credentials',
      () async {
    credentials.values[desktopHumanCredentialKey] = 'original-session';
    client.ownership = const WorkspaceOwnership(
        state: WorkspaceOwnershipState.ownedByOtherUser);
    final auth = WorkspaceHeadlessAuth(
        dataDirectory: root,
        cloudUrl: 'https://example.test',
        credentialStore: credentials,
        reloadRuntime: () async => fail('must not reload'),
        clientFactory: (_) => client);
    await auth.start();
    client.approval.complete(session());
    expect((await terminal(auth))['phase'], 'failed');
    expect(credentials.values, {desktopHumanCredentialKey: 'original-session'});
    expect(WorkspaceRegistrationStore(root).readSync(), isNull);
    await auth.close();
  });

  test(
      'existing matching ownership keeps installation, runtime and credentials',
      () async {
    final installationId = await InstallationIdentityStore(root).getOrCreate();
    await WorkspaceRegistrationStore(root).write(WorkspaceRegistration(
        installationId: installationId,
        workspaceRuntimeId: 'runtime',
        workspaceId: 'workspace',
        name: 'Server',
        cloudUrl: 'https://example.test',
        hostname: 'server',
        ownerUserId: 'user'));
    final file = File('${root.path}/workspace-registration.json');
    final before = file.readAsStringSync();
    credentials.values['runtime'] = 'existing-runtime-token';
    client.ownership = const WorkspaceOwnership(
        state: WorkspaceOwnershipState.ownedByCurrentUser,
        workspaceId: 'workspace',
        workspaceRuntimeId: 'runtime',
        ownerUserId: 'user',
        ownerMatchesCurrentSession: true,
        runtimeState: 'offline');
    final auth = WorkspaceHeadlessAuth(
        dataDirectory: root,
        cloudUrl: 'https://example.test',
        credentialStore: credentials,
        reloadRuntime: () async {},
        clientFactory: (_) => client);
    await auth.start();
    client.approval.complete(session());
    expect((await terminal(auth))['phase'], 'complete');
    expect(credentials.values['runtime'], 'existing-runtime-token');
    expect(WorkspaceRegistrationStore(root).readSync()!.installationId,
        installationId);
    expect(file.readAsStringSync(), before);
    await auth.close();
  });

  test('cancelled approval cannot persist credentials or registration',
      () async {
    final auth = WorkspaceHeadlessAuth(
        dataDirectory: root,
        cloudUrl: 'https://example.test',
        credentialStore: credentials,
        reloadRuntime: () async => fail('must not reload'),
        clientFactory: (_) => client);
    await auth.start();
    await auth.cancel();
    expect(client.cancelled, isTrue);
    client.approval.complete(session());
    expect((await terminal(auth))['phase'], 'cancelled');
    expect(credentials.values, isEmpty);
    expect(WorkspaceRegistrationStore(root).readSync(), isNull);
    await auth.close();
  });
}
