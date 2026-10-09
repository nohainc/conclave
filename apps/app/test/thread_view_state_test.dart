import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_thread_view_state.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';

void main() {
  test('thread view state round trips locally without cloud fields', () {
    const state = AxThreadViewState(
      tabIndex: 1,
      workflowReference: 'direct:v2',
      workerId: 'worker-a',
      model: 'model-a',
      reasoningEffort: 'high',
      chatDraft: 'chat draft',
      workDraft: 'work draft',
    );
    final restored = AxThreadViewState.decode(state.encode());
    expect(restored?.toJson(), state.toJson());
    expect(
        state.toJson().keys,
        containsAll([
          'tabIndex',
          'workflowReference',
          'workerId',
          'model',
          'reasoningEffort',
          'chatDraft',
          'workDraft',
        ]));
    expect(state.toJson().keys, isNot(contains('threadId')));
  });

  test('memory thread view state is isolated by user and thread', () async {
    final store = MemoryAxThreadViewStateStore();
    const state = AxThreadViewState(workDraft: 'local only');
    await store.save(userId: 'u1', threadId: 't1', state: state);
    expect(await store.load(userId: 'u1', threadId: 't1'), state);
    expect(await store.load(userId: 'u2', threadId: 't1'), isNull);
    expect(await store.load(userId: 'u1', threadId: 't2'), isNull);
    await store.clearUser('u1');
    expect(await store.load(userId: 'u1', threadId: 't1'), isNull);
  });
}
