import 'dart:io';

import 'package:conclave_profile_lab/app.dart';
import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    addTearDown(controller.dispose);
    await tester.pumpWidget(ProfileLabApp(controller: controller));

    const errorMessage = 'Profile Lab sign-in failed: Approval request expired';
    expect(find.text(errorMessage), findsOneWidget);
    expect(find.byTooltip('Copy error message'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy error message'));
    await tester.pump();
    expect(copiedText, errorMessage);
  });
}
