import 'dart:async';

abstract interface class RealtimeClient {
  Stream<Map<String, dynamic>> get events;
  Future<void> connect(Uri endpoint, String workspaceId);
  Future<void> setWorkspace(String workspaceId);
  Future<void> setScopes({
    String? projectId,
    String? workstreamId,
    String? chatId,
    String? runId,
    String? executionWorkspaceId,
  });
  Future<void> close();
}

class _StubRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect(Uri endpoint, String workspaceId) async {}

  @override
  Future<void> setWorkspace(String workspaceId) async {}
  @override
  Future<void> setScopes({
    String? projectId,
    String? workstreamId,
    String? chatId,
    String? runId,
    String? executionWorkspaceId,
  }) async {}

  @override
  Future<void> close() => _events.close();
}

RealtimeClient createRealtimeClient() => _StubRealtimeClient();
