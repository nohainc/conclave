import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_data.dart';

void main() {
  testWidgets('Project page exposes collaboration and execution areas',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProjectPage(
          project: const StudioProject(
            id: 'project-1',
            name: 'Project One',
            repository: '',
            branch: '',
            activeGoals: 0,
            lastActivity: 'today',
          ),
          dataSource: const StudioFixtureDataSource(),
          onCreateChat: () {},
          onOpenChat: (_) {},
          onEdit: () {},
          onArchive: () {},
          onDelete: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Share Project'), findsOneWidget);
    for (final label in [
      'Overview',
      'Chats',
      'Runs',
      'Artifacts',
      'Members',
      'Execution',
      'Settings',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    expect(find.text('Members'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
