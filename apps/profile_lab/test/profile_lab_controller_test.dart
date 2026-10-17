import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory temp;
  late ProfileLabController controller;
  late ProfileLabPaths paths;
  const sessionChannel = MethodChannel('profile-lab-controller-session-test');
  final sessionValues = <String, String>{};

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('lab_ctrl_test_');
    paths = ProfileLabPaths(
        homeDirectory: temp.path,
        repositoryRoot: Directory('${temp.path}/repo'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, (call) async {
      final account = (call.arguments as Map)['account'] as String;
      if (call.method == 'read') return sessionValues[account];
      if (call.method == 'write') {
        sessionValues[account] = (call.arguments as Map)['value'] as String;
      }
      if (call.method == 'delete') sessionValues.remove(account);
      return null;
    });
    controller = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.forTesting(
        paths,
        channel: sessionChannel,
      ),
    );
    await controller.initialize();
  });

  tearDown(() async {
    sessionValues.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionChannel, null);
    await temp.delete(recursive: true);
  });

  test('creates a local candidate and preserves its digest until edited',
      () async {
    await controller.createNewDraft(
      profileDefinitionId: 'candidate-profile',
      workerTypeId: 'candidate-worker',
      providerToolName: 'candidate-cli',
    );

    final initialDigest = controller.currentDraft!.payloadDigest;
    expect(controller.currentDraft!.isPublished, isFalse);
    expect(controller.isDirty, isFalse);

    final payload =
        jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
    (payload['providerTool'] as Map<String, dynamic>)['name'] =
        'candidate-cli-2';
    controller.updateJsonText(
      const JsonEncoder.withIndent('  ').convert(payload),
    );

    expect(controller.isDirty, isTrue);
    expect(controller.currentDraft!.payloadDigest, initialDigest);
    expect(controller.lastTestResult, isNull);
  });

  test('loads the Worker Profile file from the profiles folder only', () async {
    final api = _NoPublishedProfileApi();
    final noProfileController = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      apiClientOverride: api,
    );
    addTearDown(noProfileController.dispose);

    await noProfileController.selectWorker({
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'profileDefinitionId': 'chatgpt-codex',
      'providerToolName': 'codex',
    });
    expect(noProfileController.currentDraft, isNull);

    await noProfileController.createNewDraft(
      profileDefinitionId: 'chatgpt-codex',
      workerTypeId: 'chatgpt',
      providerToolName: 'codex',
    );
    await paths.profilesDirectory!.create(recursive: true);
    File('${paths.profilesDirectory!.path}/chatgpt.json')
        .writeAsStringSync(noProfileController.currentJsonText);
    await noProfileController.deleteCurrentDraft();
    expect(noProfileController.currentDraft, isNull);

    await noProfileController.loadProfileFromFolder();
    expect(noProfileController.profileFileError, isNull);

    expect(noProfileController.currentDraft, isNotNull);
    expect(
        noProfileController.currentDraft!.profileDefinitionId, 'chatgpt-codex');
    expect(noProfileController.currentDraft!.logicalWorkerTypeId, 'chatgpt');
    expect(noProfileController.currentMetadata!.provenance?['kind'],
        'imported_file');
  });

  test('rejects a Profile file that belongs to a different Worker', () async {
    final other = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      apiClientOverride: _NoPublishedProfileApi(),
    );
    addTearDown(other.dispose);
    await other.selectWorker({
      'workerTypeId': 'gemini',
      'displayName': 'Gemini',
      'profileDefinitionId': 'gemini-antigravity',
      'providerToolName': 'agy',
    });
    await paths.profilesDirectory!.create(recursive: true);
    File('${paths.profilesDirectory!.path}/gemini.json')
        .writeAsStringSync(jsonEncode({
      'logicalWorkerTypeId': 'chatgpt',
      'profileDefinitionId': 'chatgpt-codex',
    }));

    await other.loadProfileFromFolder();

    expect(other.profileFileError, contains('chatgpt'));
    expect(other.currentDraft, isNull);
  });

  test('invalid JSON reports a location and supports local recovery', () async {
    await controller.createNewDraft(
      profileDefinitionId: 'recovery-profile',
      workerTypeId: 'recovery-worker',
      providerToolName: 'recovery-cli',
    );
    const invalid = '{\n  "schemaVersion": 1,\n';
    controller.updateJsonText(invalid);

    expect(controller.jsonValidationError, isNotNull);
    expect(controller.jsonValidationLocation, startsWith('line '));
    String? recovered;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      recovered =
          await controller.store.loadLatestRecoverySnapshot('recovery-profile');
      if (recovered == invalid) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } while (DateTime.now().isBefore(deadline));
    expect(recovered, invalid);
    expect(await controller.restoreLatestRecoverySnapshot(), isTrue);
    expect(controller.currentJsonText, invalid);
  });

  test('saving a candidate clears digest-bound test state', () async {
    await controller.createNewDraft(
      profileDefinitionId: 'tested-profile',
      workerTypeId: 'tested-worker',
      providerToolName: 'tested-cli',
    );
    controller.testedDraftDigest = controller.currentDraft!.payloadDigest;
    controller.testedProfileDefinitionId =
        controller.currentDraft!.profileDefinitionId;
    controller.lastTestResult = 'pass';
    controller.testStatusMessage = '12/12 passed';

    final payload =
        jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
    (payload['providerTool'] as Map<String, dynamic>)['name'] = 'changed-cli';
    controller.updateJsonText(jsonEncode(payload));
    await controller.saveCurrentDraft();

    expect(controller.isDirty, isFalse);
    expect(controller.lastTestResult, isNull);
    expect(controller.testedDraftDigest, isNull);
    expect(controller.activeLadderStages, isEmpty);
  });

  test('provider discovery is driven by catalog and candidate metadata',
      () async {
    await controller.createNewDraft(
      profileDefinitionId: 'provider-profile',
      workerTypeId: 'provider-worker',
      providerToolName: 'candidate-cli',
    );
    final payload =
        jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
    final provider = payload['providerTool'] as Map<String, dynamic>;
    provider['name'] = 'profile-cli';
    provider['executableCandidates'] = ['profile-cli-candidate'];
    controller.updateJsonText(jsonEncode(payload));
    controller.cloudWorkers = [
      {'providerToolName': 'catalog-cli'},
    ];

    await controller.discoverInstalledProviders();

    expect(
      controller.configuredProviderExecutables,
      ['candidate-cli', 'catalog-cli', 'profile-cli', 'profile-cli-candidate'],
    );
  });

  test('session state is cleared when the Cloud origin changes', () async {
    controller.currentSession = ProfileLabSession(
      credential: 'origin-bound-credential',
      sessionId: 'origin-bound-session',
      userId: 'admin-1',
      displayName: 'Test Admin',
      email: 'test@conclave.test',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    sessionValues['profile-lab-human-session'] = 'saved-session';

    await controller.setCloudUrl('http://localhost:8787');

    expect(controller.currentSession, isNull);
    expect(sessionValues, isEmpty);
    expect(await paths.cloudSettingsFile.exists(), isTrue);
  });
}

class _NoPublishedProfileApi extends ProfileAdminApiClient {
  _NoPublishedProfileApi() : super(baseUrl: 'http://localhost');

  @override
  Future<Map<String, dynamic>> fetchCurrentWorkerProfile(
    String workerTypeId,
  ) async {
    throw ProfileAdminNotFoundException(
      'The Worker does not have a published Profile',
    );
  }
}
