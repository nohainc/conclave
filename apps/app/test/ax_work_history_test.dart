import 'dart:async';
import 'package:flutter/material.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'ax_fixture_data.dart';

AxWorkRequest request(String id, {String status = 'completed'}) =>
    AxWorkRequest(
        id: id,
        requestedByName: 'You',
        prompt: 'Prompt $id',
        workflowId: 'direct',
        workflowVersion: 2,
        status: status,
        createdAt: '2026-10-06T00:00:$id',
        steps: const []);
const older = AxWorkRequestCursor(createdAt: '2026-10-06', id: 'older');

class HistorySource extends AxFixtureDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Work',
          'steps': [
            {'kind': 'implement', 'order': 0}
          ]
        })
      ];
  final calls = <({String id, int limit, String? before, bool active})>[];
  final pending = <Completer<AxWorkRequestPage>>[];
  final detailPending = <Completer<AxWorkRequestStatus>>[];
  @override
  Future<AxWorkRequestStatus> loadWorkRequest({required String workRequestId}) {
    final result = Completer<AxWorkRequestStatus>();
    detailPending.add(result);
    return result.future;
  }

  @override
  Future<AxWorkRequestPage> loadWorkstreamWorkRequestPage(
      {required String workstreamId,
      int limit = 50,
      String? beforeCreatedAt,
      String? beforeId,
      bool activeOnly = false}) {
    calls.add(
        (id: workstreamId, limit: limit, before: beforeId, active: activeOnly));
    final future = Completer<AxWorkRequestPage>();
    pending.add(future);
    return future.future;
  }
}

void main() {
  late HistorySource source;
  late AxWorkHistoryCache cache;
  setUp(() {
    source = HistorySource();
    cache = AxWorkHistoryCache(source);
  });
  Future<void> seed({String status = 'completed'}) async {
    final load = cache.refresh('w');
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('30', status: status)], nextCursor: older));
    await load;
  }

  test('initial load requests one page of 50 and shares a future', () async {
    final load = cache.refresh('w');
    expect(identical(cache.refresh('w'), load), isTrue);
    expect(source.calls.single.limit, 50);
    source.pending.single.complete(
        AxWorkRequestPage(requests: [request('30')], nextCursor: older));
    await load;
    expect(source.calls.length, 1);
    expect(cache.peek('w').olderCursor, older);
    expect(() => cache.peek('w').requests.clear(), throwsUnsupportedError);
  });
  test(
      '5,000 Work Requests: initial 50, older 50 only on demand, no cursor traversal',
      () async {
    final server =
        List.generate(5000, (i) => request(i.toString().padLeft(4, '0')));
    final first = cache.refresh('w');
    final pageSize = source.calls.single.limit;
    expect(pageSize, 50);
    source.pending.single.complete(AxWorkRequestPage(
        requests: server.sublist(5000 - pageSize), nextCursor: older));
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(source.calls, hasLength(1));
    expect(cache.peek('w').requests, hasLength(pageSize));
    final next = cache.loadOlder('w');
    expect(source.calls, hasLength(2));
    expect(source.calls.last.before, older.id);
    expect(source.calls.last.limit, pageSize);
    source.pending.last.complete(AxWorkRequestPage(
        requests: server.sublist(5000 - 2 * pageSize, 5000 - pageSize),
        nextCursor: const AxWorkRequestCursor(createdAt: 'older', id: 'next')));
    await next;
    await Future<void>.delayed(Duration.zero);
    expect(source.calls, hasLength(2));
    expect(cache.peek('w').requests, hasLength(2 * pageSize));
    expect(cache.peek('w').requests.map((row) => row.id).toSet(),
        hasLength(2 * pageSize));
  });
  test('older pages prepend and deduplicate, refresh retains them', () async {
    await seed();
    final load = cache.loadOlder('w');
    expect(identical(load, cache.loadOlder('w')), isTrue);
    expect(source.calls.last.before, 'older');
    source.pending.last
        .complete(AxWorkRequestPage(requests: [request('10'), request('30')]));
    await load;
    expect(cache.peek('w').requests.map((r) => r.id), ['10', '30']);
    final refresh = cache.refresh('w');
    expect(cache.peek('w').requests.length, 2);
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('30'), request('40')], nextCursor: older));
    await refresh;
    await cache.loadOlder('w');
    expect(source.calls.map((c) => c.before), [null, 'older', null]);
    expect(cache.peek('w').requests.map((r) => r.id), ['10', '30', '40']);
  });
  test('refresh errors retain useful cached history', () async {
    await seed();
    final refresh = cache.refresh('w');
    final check = expectLater(refresh, throwsStateError);
    source.pending.last.completeError(StateError('offline'));
    await check;
    expect(cache.peek('w').requests.single.id, '30');
    expect(cache.error('w'), isStateError);
  });
  test('older error retains cursor and can retry', () async {
    await seed();
    final load = cache.loadOlder('w');
    final check = expectLater(load, throwsStateError);
    source.pending.last.completeError(StateError('offline'));
    await check;
    expect(cache.peek('w').olderCursor, older);
    final retry = cache.loadOlder('w');
    source.pending.last.complete(AxWorkRequestPage(requests: [request('10')]));
    await retry;
    expect(cache.error('w'), isNull);
  });
  test('active status refresh retains immutable older history', () async {
    await seed(status: 'running');
    final load = cache.loadOlder('w');
    source.pending.last.complete(AxWorkRequestPage(requests: [request('10')]));
    await load;
    final refresh = cache.refresh('w', activeOnly: true);
    expect(source.calls.last.active, isTrue);
    source.pending.last.complete(AxWorkRequestPage(requests: [request('30')]));
    await refresh;
    expect(cache.peek('w').requests.map((r) => r.id), ['10', '30']);
    expect(cache.peek('w').requests.last.status, 'completed');
  });
  test(
      'active polling follows only active pages while preserving the older frontier',
      () async {
    await seed(status: 'running');
    final refresh = cache.refresh('w', activeOnly: true);
    source.pending.last.complete(
        AxWorkRequestPage(requests: [request('30')], nextCursor: older));
    await Future<void>.delayed(Duration.zero);
    expect(source.calls.last.active, isTrue);
    expect(source.calls.last.before, 'older');
    source.pending.last.complete(
        AxWorkRequestPage(requests: [request('10', status: 'running')]));
    await refresh;
    expect(cache.peek('w').olderCursor, older);
    expect(cache.peek('w').requests.length, 2);
  });
  test('late historical overlap cannot restore an old active status', () async {
    await seed(status: 'running');
    final load = cache.loadOlder('w');
    cache.replace('w', [request('30')]);
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('10'), request('30', status: 'running')]));
    await load;
    expect(cache.peek('w').requests.last.status, 'completed');
  });
  test('repeated cursor fails rather than looping', () async {
    await seed();
    final load = cache.loadOlder('w');
    final check = expectLater(load, throwsA(isA<AxApiException>()));
    source.pending.last
        .complete(AxWorkRequestPage(requests: [], nextCursor: older));
    await check;
    expect(cache.peek('w').olderCursor, older);
  });
  test('session clearing fences both recent and older reads', () async {
    await seed();
    final old = cache.loadOlder('w');
    final head = cache.refresh('w');
    cache.clear();
    source.pending[source.pending.length - 2]
        .complete(AxWorkRequestPage(requests: [request('10')]));
    source.pending.last.complete(AxWorkRequestPage(requests: [request('40')]));
    await Future.wait([old, head]);
    expect(cache.peek('w').requests, isEmpty);
  });
  test(
      'explicit invalidation reloads older pages and preserves subscription cancellation',
      () async {
    await seed();
    var updates = 0;
    final cancel = cache.watch('w', () => updates++);
    final load = cache.loadOlder('w');
    source.pending.last.complete(AxWorkRequestPage(requests: [request('10')]));
    await load;
    cache.invalidate('w');
    await seed();
    final reload = cache.loadOlder('w');
    expect(source.calls.length, 4);
    source.pending.last.complete(AxWorkRequestPage(requests: [request('10')]));
    await reload;
    cancel();
    final count = updates;
    cache.replace('w', []);
    expect(updates, count);
  });
  test('new history gaps load on demand and resume the untouched older cursor',
      () async {
    await seed();
    final refresh = cache.refresh('w');
    const bridge = AxWorkRequestCursor(createdAt: '2026-10-07', id: 'bridge');
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('50'), request('60')], nextCursor: bridge));
    await refresh;
    expect(cache.peek('w').olderCursor, bridge);
    final fill = cache.loadOlder('w');
    expect(source.calls.last.before, 'bridge');
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('30'), request('40')],
        nextCursor: const AxWorkRequestCursor(
            createdAt: 'ignored', id: 'cached-overlap')));
    await fill;
    expect(cache.peek('w').olderCursor, older);
    expect(cache.peek('w').requests.map((r) => r.id), ['30', '40', '50', '60']);
  });

  test('an individually patched new request does not hide a history gap',
      () async {
    await seed();
    cache.patchRequest('w', request('60'));
    final head = cache.refresh('w');
    const bridge = AxWorkRequestCursor(createdAt: 'new', id: 'bridge');
    source.pending.last.complete(AxWorkRequestPage(
        requests: [request('50'), request('60')], nextCursor: bridge));
    await head;
    expect(cache.peek('w').olderCursor, bridge);
    final fill = cache.loadOlder('w');
    source.pending.last
        .complete(AxWorkRequestPage(requests: [request('30'), request('40')]));
    await fill;
    expect(cache.peek('w').olderCursor, older);
  });

  Widget page(String id,
          {Future<String> Function(
                  String, String, List<Map<String, dynamic>>, String)?
              onRun}) =>
      MaterialApp(
          home: Scaffold(
              body: WorkstreamPage(
                  key: ValueKey(id),
                  project: const AxProject(
                      id: 'p', name: 'Project', branch: '', lastActivity: ''),
                  workstream: AxWorkstream(
                      id: id,
                      projectId: 'p',
                      name: id,
                      lead: '',
                      status: 'active',
                      brief: '',
                      primaryWorkspace: '',
                      queueStatus: ''),
                  dataSource: source,
                  workHistoryCache: cache,
                  onRunWork: onRun,
                  initialTab: 1,
                  onBackToProject: () {},
                  onArchive: () {})));
  Future<void> size(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets(
      'W1 W2 W1: cached Work history renders on the first frame with network pending',
      (tester) async {
    await size(tester);
    await seed();
    await tester.pumpWidget(page('w'));
    await tester.pump();
    expect(find.text('Prompt 30'), findsOneWidget);
    source.pending.last.complete(AxWorkRequestPage(requests: [request('30')]));
    await tester.pumpAndSettle();
    await tester.pumpWidget(page('w2'));
    source.pending.last.complete(AxWorkRequestPage(requests: [request('W2')]));
    await tester.pumpAndSettle();
    expect(find.text('Prompt W2'), findsOneWidget);
    await tester.pumpWidget(page('w'));
    await tester.pump();
    expect(find.text('Prompt 30'), findsOneWidget);
    source.pending.last.complete(AxWorkRequestPage(requests: [request('30')]));
    await tester.pumpAndSettle();
  });
  testWidgets(
      'scrolling older Work history fetches one page and preserves the viewport',
      (tester) async {
    await size(tester);
    await tester.pumpWidget(page('w'));
    source.pending.last.complete(AxWorkRequestPage(
        requests: List.generate(
            50, (i) => request('b${i.toString().padLeft(3, '0')}')),
        nextCursor: older));
    await tester.pumpAndSettle();
    final history = find.byKey(const ValueKey('work-history-scroll'));
    final controller =
        tester.widget<SingleChildScrollView>(history).controller!;
    await tester.drag(history, const Offset(0, 18000));
    await tester.pump();
    expect(source.calls.last.before, 'older');
    expect(source.calls.length, 2);
    source.pending.last.complete(AxWorkRequestPage(
        requests: List.generate(
            50, (i) => request('a${i.toString().padLeft(3, '0')}'))));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(cache.peek('w').requests.length, 100);
    await tester.drag(history, const Offset(0, 18000));
    await tester.pumpAndSettle();
    expect(source.calls.length, 2);
  });
  testWidgets(
      'accepted submission reconciles shared history after the page is destroyed',
      (tester) async {
    await size(tester);
    final submit = Completer<String>();
    await tester
        .pumpWidget(page('w', onRun: (_, __, ___, key) => submit.future));
    source.pending.last.complete(AxWorkRequestPage(requests: []));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Send this Work');
    await tester.tap(find.byTooltip('Run Work'));
    await tester.pump();
    expect(cache.peek('w').requests.single.id, startsWith('local-'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    submit.complete('saved');
    await tester.pump();
    expect(cache.peek('w').requests.single.id, 'saved');
    source.detailPending.last
        .complete(const AxWorkRequestStatus(id: 'saved', status: 'completed'));
    await tester.pumpAndSettle();
    expect(cache.peek('w').requests.single.status, 'completed');
  });
}
