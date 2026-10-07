import 'dart:convert';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_cli_worker_engine/src/conversation_execution_router.dart';
import 'package:conclave_cli_worker_engine/src/worker_session.dart';
import 'package:test/test.dart';

void main() {
  const router = ConversationExecutionRouter();
  final bootstrap = ConversationBootstrap(
    conversationId: 'C',
    contextRevision: 1,
    turnRevision: 2,
    throughSequence: 2,
    text: jsonEncode({
      'conversationId': 'C',
      'throughSequence': 2,
      'history': [
        {
          'sequence': 1,
          'contextRevision': 1,
          'kind': 'user_message',
          'text': 'Prior question',
        },
        {
          'sequence': 2,
          'contextRevision': 1,
          'kind': 'worker_response',
          'text': 'Prior answer',
        },
      ],
    }),
  );
  WorkerSession stored(int revision, int sequence) => WorkerSession(
    id: 'S',
    conversationId: 'C',
    workerId: 'W',
    profileId: 'profile',
    profileVersion: 1,
    nativeSessionId: 'native',
    synchronizedContextRevision: revision,
    synchronizedHistorySequence: sequence,
    status: 'active',
    lastModelId: 'model-x',
    lastEffort: 'medium',
    createdAt: 'now',
    lastUsedAt: 'now',
  );
  ExecuteRequest request({bool context = true}) => ExecuteRequest(
    requestId: 'R',
    assignmentId: 'A',
    prompt: 'New question',
    timeoutMs: 10000,
    sessionPolicy: WorkerSessionPolicy.durableSession,
    sessionKey: 'key',
    model: 'model-y',
    reasoningEffort: 'high',
    workerSession: WorkerSessionContext(
      id: 'S',
      conversationId: 'C',
      workerId: 'W',
      baseContextRevision: 1,
      bootstrap: context ? bootstrap : null,
    ),
  );

  test(
    'runtime router separates all five continuity actions from provider invocation',
    () {
      final current = router.prepare(
        request(),
        nativeSessionId: 'native',
        storedSession: stored(1, 2),
      );
      expect(current.action, ConversationExecutionAction.continueSession);
      expect(current.prompt, 'New question');
      final sync = router.prepare(
        request(),
        nativeSessionId: 'native',
        storedSession: stored(0, 0),
      );
      expect(sync.action, ConversationExecutionAction.syncAndContinue);
      expect(sync.prompt, contains('Canonical Conclave conversation context'));
      expect(sync.prompt, contains('Prior answer'));
      expect(
        router.prepare(request()).action,
        ConversationExecutionAction.bootstrapSession,
      );
      final replacement = router.prepare(
        request(),
        storedSession: stored(1, 2),
        reconstruct: true,
      );
      expect(
        replacement.action,
        ConversationExecutionAction.reconstructSession,
      );
      expect(replacement.prompt, contains(bootstrap.text));
      final stateless = router.prepare(
        ExecuteRequest(
          requestId: 'R',
          assignmentId: 'A',
          prompt: 'New question',
          timeoutMs: 10000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          statelessContext: bootstrap,
        ),
      );
      expect(stateless.action, ConversationExecutionAction.statelessExecution);
      expect(stateless.prompt, contains('Prior question'));
      expect(bootstrap.contextRevision, 1);
      expect(stored(1, 2).synchronizedContextRevision, 1);
    },
  );

  test(
    'missing canonical reconstruction context is rejected before execution',
    () {
      expect(
        () => router.prepare(request(context: false)),
        throwsFormatException,
      );
      expect(
        () => router.prepare(
          request(context: false),
          nativeSessionId: 'native',
          reconstruct: true,
        ),
        throwsFormatException,
      );
    },
  );
}
