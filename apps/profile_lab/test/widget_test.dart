import 'dart:io';

import 'package:conclave_profile_lab/app.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_auth.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_admin_api_client.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders ProfileLabApp and interacts with tabs', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final temp = Directory.systemTemp.createTempSync('widget_test_lab_');
    try {
      final paths = ProfileLabPaths(homeDirectory: temp.path);
      final controller = ProfileLabController(
        paths: paths,
        sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
      );
      await tester.pumpWidget(ProfileLabApp(controller: controller));
      expect(find.text('CONCLAVE'), findsOneWidget);
      expect(find.text('PROFILE LAB'), findsOneWidget);
      expect(find.text('Workers'), findsOneWidget);
      expect(find.text('Profiles'), findsOneWidget);
      expect(find.text('Tests'), findsOneWidget);
      expect(find.text('Releases'), findsOneWidget);
      expect(find.text('Audit'), findsOneWidget);

      for (final tab in ['Profiles', 'Tests', 'Releases', 'Audit']) {
        await tester.tap(find.text(tab));
        await tester.pump();
        expect(
            find.text(
                'Profile Lab access is unavailable. Check access or sign in with the authorized owner account.'),
            findsOneWidget);
        expect(controller.selectedTab.name, tab.toLowerCase());
      }

      // Verify authentication UI states
      expect(find.text('Sign In'), findsOneWidget);

      controller.setSessionForTesting(ProfileLabSession(
        credential: 'conclave_dhs_mock',
        sessionId: 'session-mock',
        userId: 'admin-mock',
        displayName: 'Security Lead',
        email: 'lead@conclave.test',
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      ));
      await tester.pump();

      expect(find.text('Security Lead'), findsOneWidget);
      expect(find.text('Signed in'), findsOneWidget);
      expect(find.text('Profile Admin'), findsNothing);
      expect(find.text('PROFILE WORKBENCH'), findsNothing);
      controller.labAccess = ProfileLabAccessReadModel.fromJson({
        'permissions': {'profilesAdmin': true, 'releaseManager': true},
        'signer': {'ready': false},
        'releaseMode': 'drafts-only'
      });
      controller.setSessionForTesting(controller.currentSession);
      await tester.pump();
      expect(find.text('Profile Admin'), findsOneWidget);
      await tester.tap(find.text('Profiles'));
      await tester.pump();
      expect(find.text('PROFILE WORKBENCH'), findsOneWidget);
      expect(controller.canPublish, isFalse);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  testWidgets('shows a copyable sign-in error', (tester) async {
    final temp = Directory.systemTemp.createTempSync('widget_test_lab_auth_');
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      temp.deleteSync(recursive: true);
    });

    final paths = ProfileLabPaths(homeDirectory: temp.path);
    final controller = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
    )..authError = 'Approval request expired';

    await tester.pumpWidget(ProfileLabApp(controller: controller));

    const errorMessage = 'Profile Lab sign-in failed: Approval request expired';
    expect(find.text(errorMessage), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy error message'));
    await tester.pump();
    expect(copiedText, errorMessage);
  });
}
