import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/notes/notes_page.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'ax_fixture_data.dart';

/// In-memory notes with the Cloud's revision rule.
class NotesSource extends AxFixtureDataSource implements AxNotesDataSource {
  final notes = <String, AxNote>{};
  final threadNotes = <String, String>{};
  int _next = 0;

  AxNote _put(AxNote note) => notes[note.id] = note;

  AxNote _write(AxNote current,
      {String? title, String? body, required int revision}) {
    if (revision != current.revision) {
      throw const AxApiException('stale', statusCode: 409);
    }
    return _put(AxNote(
      id: current.id,
      title: title ?? current.title,
      body: body ?? current.body,
      revision: current.revision + 1,
      updatedAt: 'now',
      threadId: current.threadId,
      spaceId: current.spaceId,
      threadName: current.threadName,
      linked: current.linked,
    ));
  }

  @override
  Future<List<AxNote>> loadNotes() async => notes.values.toList();

  @override
  Future<AxNote> loadNote(String id) async => notes[id]!;

  @override
  Future<AxNote> createNote({String title = '', String body = ''}) async =>
      _put(AxNote(
          id: 'n${_next++}',
          title: title,
          body: body,
          revision: 1,
          updatedAt: 'now'));

  @override
  Future<AxNote> updateNote(String id,
          {String? title, String? body, required int revision}) async =>
      _write(notes[id]!, title: title, body: body, revision: revision);

  @override
  Future<void> deleteNote(String id) async => notes.remove(id);

  @override
  Future<AxNote?> loadThreadNote(String threadId) async =>
      notes[threadNotes[threadId]];

  @override
  Future<AxNote> saveThreadNote(String threadId,
      {required String body, int? revision}) async {
    final existing = notes[threadNotes[threadId]];
    if (existing != null) {
      return _write(existing, body: body, revision: revision ?? 0);
    }
    if (revision != null) throw const AxApiException('stale', statusCode: 409);
    final note = _put(AxNote(
        id: 'n${_next++}',
        title: '',
        body: body,
        revision: 1,
        updatedAt: 'now',
        threadId: threadId,
        spaceId: 's',
        threadName: 'Thread',
        linked: true));
    threadNotes[threadId] = note.id;
    return note;
  }
}

Widget threadPage(AxDataSource source) => MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space:
          const AxSpace(id: 's', name: 'Space', branch: '', lastActivity: ''),
      thread: const AxThread(
          id: 't',
          spaceId: 's',
          name: 'Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      dataSource: source,
      onBackToSpace: () {},
      onArchive: () {},
    )));

void main() {
  test('My Notes has its own route', () {
    expect(AxNavigation.fromUri(Uri(path: '/notes')).kind, AxRouteKind.notes);
    expect(const AxNavigation.notes().toUri().path, '/notes');
  });

  test('display title falls back to Thread name, then first line', () {
    AxNote note({String title = '', String body = '', String? thread}) =>
        AxNote(
            id: 'n',
            title: title,
            body: body,
            revision: 1,
            updatedAt: '',
            threadName: thread);
    expect(note(title: 'T', thread: 'X').displayTitle, 'T');
    expect(note(thread: 'X', body: 'b').displayTitle, 'X');
    expect(note(body: '\nfirst\nsecond').displayTitle, 'first');
    expect(note().displayTitle, 'Untitled note');
  });

  testWidgets('Thread Notes tab saves a private note automatically',
      (tester) async {
    final source = NotesSource();
    await tester.pumpWidget(threadPage(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Only you can see these notes.'), findsOneWidget);
    // Composer and clear actions belong to the other tabs.
    expect(find.byKey(const ValueKey('clear-ai-history')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('note-body')), 'first');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(source.notes.values.single.body, 'first');
    expect(source.notes.values.single.threadId, 't');
    expect(find.text('Saved'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('note-body')), 'second');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(source.notes.values.single.body, 'second');
    expect(source.notes.values.single.revision, 2);

    await tester.tap(find.byKey(const ValueKey('notes-conversation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-toggle')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a stale save reloads the latest text instead of overwriting',
      (tester) async {
    final source = NotesSource();
    final note = await source.saveThreadNote('t', body: 'mine');
    await tester.pumpWidget(threadPage(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('mine'), findsOneWidget);

    // Another device saves first.
    await source.saveThreadNote('t', body: 'other device', revision: 1);
    await tester.enterText(find.byKey(const ValueKey('note-body')), 'stale');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(source.notes[note.id]!.body, 'other device');
    expect(find.text('other device'), findsOneWidget);
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('My Notes lists notes from deleted Threads', (tester) async {
    final source = NotesSource();
    source.notes['kept'] = const AxNote(
        id: 'kept',
        title: '',
        body: 'still here',
        revision: 1,
        updatedAt: 'now',
        threadId: 'gone',
        spaceId: 's',
        threadName: 'Old Thread',
        linked: false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: NotesPage(source: source)))));
    await tester.pumpAndSettle();
    expect(find.text('Old Thread'), findsOneWidget);
    expect(find.text('From a Thread you can no longer open: Old Thread'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-note')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('note-title')), 'Ideas');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Ideas'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-note-kept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-note')));
    await tester.pumpAndSettle();
    expect(source.notes.containsKey('kept'), isFalse);
    expect(find.text('Old Thread'), findsNothing);
  });

  testWidgets('Notes tab is hidden without a notes data source',
      (tester) async {
    await tester.pumpWidget(threadPage(const AxFixtureDataSource()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes-toggle')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
