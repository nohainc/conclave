import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/sync/ax_archived_spaces.dart';
import 'package:conclave_app/src/ax/sync/ax_collaboration_mutations.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/archived_spaces_page.dart';

import 'ax_fixture_data.dart';

class _ArchivedSource extends AxFixtureDataSource {
  _ArchivedSource(this.archived);

  final List<AxSpace> archived;

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      includeArchived ? archived : const [];
}

void main() {
  const first = AxSpace(
    id: 'archived-1',
    name: 'Research',
    branch: 'main',
    lastActivity: 'yesterday',
    description: 'Research notes',
    archived: true,
  );
  const second = AxSpace(
    id: 'archived-2',
    name: 'Holiday planning',
    branch: 'main',
    lastActivity: 'last week',
    description: 'Trip planning',
    archived: true,
  );

  test('refreshes an existing archived inventory cache', () async {
    final source = _ArchivedSource([]);
    final engine = AxSyncEngine();
    final archivedSpaces = AxArchivedSpaces(source, engine: engine);

    await archivedSpaces.ensure();
    source.archived.add(first);
    await archivedSpaces.ensure();
    await Future<void>.delayed(Duration.zero);

    expect(engine.peek(archivedSpaces.query).data?.single.name, first.name);
  });

  testWidgets('shows archived Spaces in a responsive two-column page',
      (tester) async {
    final source = _ArchivedSource([first, second]);
    final engine = AxSyncEngine();
    final archivedSpaces = AxArchivedSpaces(source, engine: engine);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1000, 800)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ArchivedSpacesPage(
                archivedSpaces: archivedSpaces,
                mutations: AxCollaborationMutations(source, engine: engine),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived Spaces'), findsOneWidget);
    expect(find.text('Spaces you archived are kept here until restored.'),
        findsOneWidget);
    expect(find.byIcon(Icons.archive_outlined), findsNothing);
    expect(find.byKey(const ValueKey('archived-space-archived-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('archived-space-archived-2')),
        findsOneWidget);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('archived-space-archived-2')))
          .dx,
      greaterThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('archived-space-archived-1')))
            .dx,
      ),
    );
    expect(find.text('Restore'), findsNWidgets(2));
    expect(find.text('Delete'), findsNWidgets(2));

    await tester
        .tap(find.byKey(const ValueKey('delete-archived-space-archived-1')));
    await tester.pumpAndSettle();
    expect(find.text('Delete Research?'), findsOneWidget);
    expect(
        find.text(
            'This permanently deletes the Space and its archived record.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Research?'), findsNothing);
  });
}
