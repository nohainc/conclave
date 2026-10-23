import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
import 'package:conclave_app/src/features/notes/note_editor.dart';
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
      spaceName: current.spaceName,
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
        title: 'Thread',
        body: body,
        revision: 1,
        updatedAt: 'now',
        threadId: threadId,
        spaceId: 's',
        threadName: 'Thread',
        spaceName: 'Space',
        linked: true));
    threadNotes[threadId] = note.id;
    return note;
  }
}

Widget threadPage(AxDataSource source,
        {String threadId = 't',
        String? userId,
        AxThreadViewStateStore? store}) =>
    MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space:
          const AxSpace(id: 's', name: 'Space', branch: '', lastActivity: ''),
      currentUserId: userId,
      threadViewStateStore: store,
      thread: AxThread(
          id: threadId,
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
    expect(
        const AxNote(
                id: 'n',
                title: '',
                body: '',
                revision: 1,
                updatedAt: '',
                threadId: 't',
                spaceName: 'Space',
                threadName: 'Thread')
            .path,
        'Thread < Space');
    expect(note().path, isNull);
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

  testWidgets('Notes toolbar formats Markdown, inserts emoji and previews',
      (tester) async {
    final source = NotesSource();
    await tester.pumpWidget(threadPage(source));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show Markdown controls'), findsOneWidget);

    await tester.tap(find.byTooltip('Show Markdown controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    // Toolbar edits save like typing does.
    expect(source.notes.values.single.body, '**bold text**');

    // Done sits on the left, then a separator, then the editing tools.
    final done = tester.getCenter(find.byKey(const ValueKey('note-done'))).dx;
    final separator = tester
        .getCenter(find.byKey(const ValueKey('note-toolbar-separator')))
        .dx;
    expect(done, lessThan(separator));
    expect(
        separator,
        lessThan(
            tester.getCenter(find.byTooltip('Show Markdown controls')).dx));

    // Done shows the note formatted and read-only; the tools stay visible
    // but disabled until Edit.
    IconButton markdownButton() => tester.widget<IconButton>(find.ancestor(
        of: find.byTooltip('Show Markdown controls'),
        matching: find.byType(IconButton)));
    await tester.tap(find.byKey(const ValueKey('note-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-body')), findsNothing);
    expect(find.byTooltip('Show Markdown controls'), findsOneWidget);
    expect(markdownButton().onPressed, isNull);
    // Disabled tools also look disabled.
    final disabled =
        Theme.of(tester.element(find.byType(NoteEditor))).disabledColor;
    expect(tester.widget<Icon>(find.byIcon(Icons.text_format)).color, disabled);

    await tester.tap(find.byKey(const ValueKey('note-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-body')), findsOneWidget);
    expect(markdownButton().onPressed, isNotNull);
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
    // A saved note opens formatted; a double click edits it.
    expect(find.byKey(const ValueKey('note-body')), findsNothing);
    expect(find.byKey(const ValueKey('note-edit')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('note-edit')),
            matching: find.text('Edit')),
        findsOneWidget);
    expect(
        tester.getCenter(find.byKey(const ValueKey('note-edit'))).dx,
        lessThan(
            tester.getCenter(find.byKey(const ValueKey('note-preview'))).dx));
    final preview = find.byKey(const ValueKey('note-preview'));
    await tester.tap(preview);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('note-body')), findsOneWidget);
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
        spaceName: 'Old Space',
        linked: false);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: NotesPage(source: source))));
    await tester.pumpAndSettle();
    expect(find.text('Old Thread'), findsOneWidget);
    expect(find.text('Old Thread < Old Space (Thread no longer available)'),
        findsOneWidget);
    // Delete sits below the path, beside the preview.
    expect(
        tester.getRect(find.byKey(const ValueKey('delete-note-kept'))).top,
        greaterThanOrEqualTo(tester
            .getRect(find.byKey(const ValueKey('note-path-kept')))
            .bottom));
    // The path sits on the right of the name.
    expect(tester.getCenter(find.byKey(const ValueKey('note-path-kept'))).dx,
        greaterThan(tester.getCenter(find.text('Old Thread')).dx));

    await tester.tap(find.byKey(const ValueKey('new-note')));
    await tester.pumpAndSettle();
    // The editor replaces the list on the page; no pop-up.
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('new-note')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('note-title')), 'Ideas');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-back')));
    await tester.pumpAndSettle();
    expect(find.text('Ideas'), findsOneWidget);

    // A Thread note's page shows Space > Thread and fills the page height.
    await tester.tap(find.text('Old Thread'));
    await tester.pumpAndSettle();
    expect(find.text('Old Space > Old Thread (Thread no longer available)'),
        findsOneWidget);
    expect(
        tester.getSize(find.byType(NoteEditor)).height,
        greaterThan(
            tester.view.physicalSize.height / tester.view.devicePixelRatio -
                120));
    await tester.tap(find.byKey(const ValueKey('notes-back')));
    await tester.pumpAndSettle();

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

  testWidgets('each Thread reopens its own last tab', (tester) async {
    final source = NotesSource();
    final store = MemoryAxThreadViewStateStore();
    Future<void> open(String threadId) async {
      await tester.pumpWidget(
          threadPage(source, threadId: threadId, userId: 'u', store: store));
      await tester.pumpAndSettle();
    }

    bool notesOpen() =>
        find.text('Only you can see these notes.').evaluate().isNotEmpty;
    bool historyOpen() =>
        find.byKey(const ValueKey('ai-history-tab')).evaluate().isNotEmpty;

    await open('a');
    await tester.tap(find.byKey(const ValueKey('notes-toggle')));
    await tester.pumpAndSettle();
    expect(notesOpen(), isTrue);

    // Switching Threads reuses the page; an unsaved Thread starts on
    // Conversation instead of inheriting Notes.
    await open('b');
    expect(notesOpen(), isFalse);
    expect(historyOpen(), isFalse);
    await tester.tap(find.byKey(const ValueKey('ai-history-toggle')));
    await tester.pumpAndSettle();
    expect(historyOpen(), isTrue);

    await open('a');
    expect(notesOpen(), isTrue);
    await open('b');
    expect(historyOpen(), isTrue);
    await tester.tap(find.byKey(const ValueKey('ai-history-conversation')));
    await tester.pumpAndSettle();

    // A fresh page (reload) restores from the store as well.
    await tester.pumpWidget(const SizedBox());
    await open('b');
    expect(historyOpen(), isFalse);
    expect(find.byKey(const ValueKey('conversation-tab')), findsOneWidget);
    await open('a');
    expect(notesOpen(), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
