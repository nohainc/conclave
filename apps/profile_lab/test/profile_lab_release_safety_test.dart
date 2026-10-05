import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/views/releases_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Profile Lab release safety controls', () {
    late Directory temp;
    late ProfileLabController controller;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('profile_lab_release_');
      controller = ProfileLabController(
        paths: ProfileLabPaths(homeDirectory: temp.path),
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(
          ProfileLabPaths(homeDirectory: temp.path),
        ),
      );
      controller.setApiClientForTesting(_OfflineProfileAdminApiClient());
      controller.selectedDefinitionId = 'test-profile';
    });

    tearDown(() async {
      controller.dispose();
      await temp.delete(recursive: true);
    });

    test('controller requires a stored evidence ID for Stable promotion',
        () async {
      await expectLater(
        controller.promoteCloudRelease(
          releaseVersion: 1,
          channel: 'stable',
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('qualifying Cloud evidence record'),
        )),
      );
    });

    test('controller refuses channels outside the available Beta path',
        () async {
      await expectLater(
        controller.promoteCloudRelease(
          releaseVersion: 1,
          channel: 'testing',
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('beta or stable'),
        )),
      );
    });

    testWidgets('Beta release exposes Stable promotion through Cloud evidence',
        (tester) async {
      final release = <String, dynamic>{
        'releaseVersion': 1,
        'profileDefinitionId': 'test-profile',
        'workerTypeId': 'test-worker',
        'lifecycleState': 'beta',
        'signature': 'signature',
        'signingKeyId': 'test-key',
        'payloadDigest': 'digest',
        'profile': {'profileDefinitionId': 'test-profile'},
      };
      controller.cloudReleases = [release];
      controller.selectedCloudRelease = release;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1600,
              height: 1000,
              child: ReleasesView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Promote to Stable'), findsOneWidget);
      expect(find.text('Cloud acceptance evidence'), findsOneWidget);
      expect(find.text('Revoke release…'), findsNothing);
      expect(find.text('Promote to Beta'), findsNothing);
    });
    testWidgets(
        'Cloud drafts show empty published state and return to workbench',
        (tester) async {
      controller.cloudReleases = [
        {'releaseVersion': 1, 'lifecycleState': 'draft'}
      ];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ReleasesView(controller: controller))));
      expect(find.text('No published Profile yet'), findsOneWidget);
      await tester.tap(find.text('Draft & Test'));
      expect(controller.workerSubView, WorkerSubView.draftAndTest);
    });

    testWidgets(
        'channel assignments and previous version drive release inspector',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.selectedCloudDefinition = {
        'channels': {'testing': 2, 'beta': 1, 'stable': null}
      };
      controller.cloudReleases = [
        {'releaseVersion': 3, 'lifecycleState': 'draft'},
        {
          'releaseVersion': 2,
          'lifecycleState': 'beta',
          'profile': <String, dynamic>{
            'providerTool': <String, dynamic>{
              'name': 'Example CLI',
              'supportedVersions': [
                {'min': '2.0.0', 'maxExclusive': '3.0.0'}
              ]
            }
          }
        },
        {
          'releaseVersion': 1,
          'lifecycleState': 'testing',
          'profile': <String, dynamic>{}
        },
      ];
      controller.selectedCloudRelease = controller.cloudReleases[1];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ReleasesView(controller: controller))));
      expect(find.text('Testing'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Stable'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('v3'), findsNothing);
      expect(find.text('Compare with v1'), findsOneWidget);
      expect(
          find.text('Example CLI · 2.0.0 ≤ version < 3.0.0'), findsOneWidget);
      await tester.tap(find.byTooltip('Release actions'));
      await tester.pumpAndSettle();
      expect(find.text('Rollback channel…'), findsOneWidget);
      expect(find.text('Revoke release…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('promotion remains available without a configured signer',
        (tester) async {
      controller.labAccess = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'releaseManager': true},
        'signer': {'ready': false},
      });
      controller.cloudReleases = [
        {
          'releaseVersion': 1,
          'lifecycleState': 'testing',
          'profile': <String, dynamic>{}
        }
      ];
      controller.selectedCloudRelease = controller.cloudReleases.first;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ReleasesView(controller: controller))));
      expect(find.text('Promote to Beta'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _OfflineProfileAdminApiClient extends ProfileAdminApiClient {
  _OfflineProfileAdminApiClient() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<ProfileLabReleaseReadModel> fetchRelease(
          String profileDefinitionId, int releaseVersion) async =>
      ProfileLabReleaseReadModel.fromJson({});
}
