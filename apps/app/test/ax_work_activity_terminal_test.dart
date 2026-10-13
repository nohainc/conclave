import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_work_activity.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';

void main() {
  testWidgets('does not show an unfinished activity after terminal failure',
      (tester) async {
    final activity = AxWorkActivity(
      eventId: 'tool-started',
      assignmentId: 'assignment-1',
      attemptId: 'attempt-1',
      executionId: 'execution-1',
      workerId: 'chatgpt',
      activitySequence: 1,
      streamSequence: 1,
      type: 'tool.started',
      status: 'running',
      title: 'Running repository checks',
      timestamp: DateTime.utc(2026, 10, 13),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AxWorkerActivityPanel(
          workerName: 'ChatGPT',
          providerToolName: 'codex',
          requestStatus: 'failed',
          activities: [activity],
        ),
      ),
    ));

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Running repository checks'), findsNothing);
  });
}
