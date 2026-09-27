import 'package:flutter/material.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:conclave_app/src/studio/studio_app.dart';
import 'package:conclave_app/src/studio/studio_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_fixture_data.dart';

class _SignedInDesktopAuthFixture extends StudioFixtureDataSource {
  const _SignedInDesktopAuthFixture();

  @override
  Future<StudioSession> loadSession() async => const StudioSession(
        authenticated: true,
        viewer: StudioViewer(
          id: 'user-1',
          displayName: 'Ada Lovelace',
          email: 'ada@example.test',
        ),
      );
}

void main() {
  testWidgets('desktop approval uses the signed-in account without a code',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: const _SignedInDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-1'},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ada Lovelace'), findsOneWidget);
    expect(find.text('Approve sign-in'), findsOneWidget);
    expect(find.textContaining('code'), findsNothing);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Approve sign-in'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in approved'), findsOneWidget);
    expect(find.text('Return to Conclave Workspace to finish signing in.'),
        findsOneWidget);
    expect(
        find.text(
            'Your browser did not allow this tab to close. You can close it now.'),
        findsOneWidget);
  });
}
