import 'package:conclave_app/src/ax/ax_work_models.dart';

AxConversationTurn turnFixture(
        {String id = 'turn-A',
        String requestId = 'R',
        String? model = 'model-x',
        String? effort = 'medium'}) =>
    AxConversationTurn.fromJson({
      'id': id,
      'conversationId': 'conversation-C',
      'workflowId': 'direct',
      'workflowVersion': 2,
      'userMessageId': 'message-user-$requestId',
      'workRequestId': requestId,
      'workflowRunId': 'workflow-run-$requestId',
      'workflowStepRunId': 'step-run-task-$requestId',
      'assignmentId': 'assignment-$id',
      'taskId': 'task-$requestId',
      'stepKind': 'implement',
      'workerId': 'worker-a',
      'workerTypeId': 'chatgpt',
      'workerDisplayName': 'ChatGPT',
      'profileId': 'chatgpt-codex',
      'profileVersion': 3,
      'modelId': model,
      'effort': effort,
      'workerSessionId': 'worker-session-opaque',
      'baseContextRevision': 0,
      'status': 'completed',
      'startedAt': '2026-10-07T10:00:00Z',
      'completedAt': '2026-10-07T10:01:00Z',
      'resultText': '**Recorded answer**',
      'createdAt': '2026-10-07T10:00:00Z',
    });
