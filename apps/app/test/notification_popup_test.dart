import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/app_shell.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/brand.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'package:conclave_app/src/features/navigation/resizable_sidebar.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

class _NotificationSource extends AxFixtureDataSource
    implements AxNotificationDataSource {
  bool markedRead = false;

  @override
  Future<List<Map<String, dynamic>>> loadNotificationFeed() async => [
        {
          'id': 'failed',
          'type': 'thread.failed',
          'threadId': 't',
          'read': false
        }
      ];

  @override
  Future<void> markNotificationsRead({List<String>? ids}) async {
    markedRead = true;
  }
}

class _HomeNotificationSource extends _NotificationSource {
  List<String>? readIds;
  @override
  Future<List<Map<String, dynamic>>> loadNotificationFeed() async => [
        {
          'id': 'home-failed',
          'type': 'work_request.failed',
          'spaceId': 'space-auth',
          'threadId': 'thread-auth',
          'read': markedRead
        },
      ];
  @override
  Future<void> markNotificationsRead({List<String>? ids}) async {
    readIds = ids;
    markedRead = true;
  }
}

void main() {
  testWidgets('Home marks opened notifications read and keeps them in Inbox',
      (tester) async {
    final source = _HomeNotificationSource();
    final realtime = TestRealtime();
    await tester.pumpWidget(MaterialApp(
        home: ConclaveAppShell(
            services: const DefaultPlatformServices(),
            dataSource: source,
            realtimeClient: realtime,
            initialUri: Uri.parse('/'))));
    await tester.pumpAndSettle();
    realtime.emit({'type': 'realtime.ready'});
    await tester.pumpAndSettle();
    expect(find.text('Thread failed'), findsOneWidget);
    await tester.tap(find.text('Thread failed'));
    await tester.pumpAndSettle();
    expect(source.readIds, ['home-failed']);
    // Return Home through the brand button.
    await tester.tap(find.byTooltip('Conclave AX — Home'));
    await tester.pumpAndSettle();
    expect(find.text('Thread failed'), findsNothing);
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();
    expect(find.text('Thread failed'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mode in ['expanded', 'resized', 'collapsed', 'mobile']) {
    testWidgets('Inbox placement follows $mode navigation', (tester) async {
      final mobile = mode == 'mobile';
      final width = mobile ? 390.0 : 1000.0;
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = _NotificationSource();
      await tester.pumpWidget(MaterialApp(
          home: ConclaveAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: TestRealtime(),
        initialUri: Uri.parse('/settings/profile'),
      )));
      await tester.pumpAndSettle();
      if (mode == 'resized') {
        await tester.drag(find.byKey(const ValueKey('sidebar-resize-handle')),
            const Offset(70, 0));
        await tester.pumpAndSettle();
      }
      final sidebarWidth = mobile
          ? 0.0
          : mode == 'collapsed'
              ? 50.0
              : tester.getSize(find.byType(ResizableSidebar)).width;
      if (mode == 'collapsed') {
        await tester.tap(find.byTooltip('Hide sidebar'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      final surface = find
          .ancestor(of: find.text('Inbox'), matching: find.byType(Material))
          .first;
      final rect = tester.getRect(surface);
      if (mobile) {
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(rect.left, 0);
        expect(rect.width, width);
        expect(rect.bottom, 800);
      } else {
        expect(find.byType(BottomSheet), findsNothing);
        expect(rect.left, sidebarWidth + 8);
        expect(rect.right, lessThanOrEqualTo(width));
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Inbox'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final dark in [false, true]) {
    testWidgets('Inbox uses header icon actions in dark=$dark', (tester) async {
      final source = _NotificationSource();
      final realtime = TestRealtime();
      await tester.pumpWidget(MaterialApp(
        theme: dark ? ConclaveBrand.darkTheme() : ConclaveBrand.lightTheme(),
        home: ConclaveAppShell(
          services: const DefaultPlatformServices(),
          dataSource: source,
          realtimeClient: realtime,
          initialUri: Uri.parse('/settings/profile'),
        ),
      ));
      await tester.pumpAndSettle();
      realtime.emit({'type': 'realtime.ready'});
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Thread failed'), findsOneWidget);
      expect(find.textContaining('Thread activity failed'), findsNothing);
      expect(find.textContaining('priority'), findsNothing);
      final record = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Thread failed'));
      expect(record.trailing, isNull);
      expect(record.leading, isA<Icon>());
      expect(
          find.descendant(
              of: find.widgetWithText(ListTile, 'Thread failed'),
              matching: find.byType(Icon)),
          findsOneWidget);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.actions, isNull);
      final header = find.byWidget(dialog.title!);
      final markRead = find.byTooltip('Mark all as read');
      final close = find.byTooltip('Close');
      for (final action in [markRead, close]) {
        expect(find.descendant(of: header, matching: action), findsOneWidget);
        expect(tester.getCenter(action).dx,
            greaterThan(tester.getCenter(find.text('Inbox')).dx));
      }
      expect(find.text('Mark all as read'), findsNothing);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(source.markedRead, isFalse);
      await tester.tap(find.byTooltip('Notifications'));
      await tester.pumpAndSettle();
      await tester.tap(markRead);
      await tester.pumpAndSettle();
      expect(source.markedRead, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
