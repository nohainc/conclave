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

      expect(find.textContaining('Stable promotion requires'), findsOneWidget);
      expect(find.text('Requires Cloud evidence'), findsOneWidget);
      expect(
        find.byTooltip('Promote to Stable using Cloud evidence'),
        findsOneWidget,
      );
      expect(find.text('Promote to Beta'), findsNothing);
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
