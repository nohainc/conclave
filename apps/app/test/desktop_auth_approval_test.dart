import 'package:flutter/material.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';

class _SignedInDesktopAuthFixture extends AxFixtureDataSource {
  const _SignedInDesktopAuthFixture();

  @override
  Future<AxSession> loadSession() async => const AxSession(
        authenticated: true,
        viewer: AxViewer(
          id: 'user-1',
          displayName: 'Ada Lovelace',
          email: 'ada@example.test',
        ),
      );
}

class _CanceledDesktopAuthFixture extends _SignedInDesktopAuthFixture {
  @override
  Future<String> loadDesktopAuthIntentStatus(
          {required String intentId}) async =>
      'denied';
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
        find.text('You can close this page, window, or tab.'), findsOneWidget);
    expect(find.text('Close tab'), findsNothing);
  });

  testWidgets('a remotely canceled intent explains how to close the page',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: _CanceledDesktopAuthFixture(),
        initialUri: Uri(
          path: '/desktop-auth/approve',
          queryParameters: {'intentId': 'intent-1'},
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in canceled'), findsOneWidget);
    expect(
        find.text('You can close this page, window, or tab.'), findsOneWidget);
    expect(find.text('Close tab'), findsNothing);
  });
}
