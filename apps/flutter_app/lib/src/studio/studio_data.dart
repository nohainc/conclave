import 'dart:convert';

import 'package:http/http.dart' as http;

import 'studio_models.dart';

abstract interface class StudioDataSource {
  Future<StudioSnapshot> loadSnapshot({String? projectId});
  Future<void> controlRun(String runId, String command);
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  });
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  });
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  });
}

class StudioApiException implements Exception {
  const StudioApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StudioApiClient implements StudioDataSource {
  StudioApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ??
            const String.fromEnvironment(
              'CONCLAVE_API_URL',
              defaultValue: 'http://localhost:8787/api',
            ),
        client = client ?? http.Client();

  final String baseUrl;
  final http.Client client;

  @override
  Future<StudioSnapshot> loadSnapshot({String? projectId}) async {
    final uri = Uri.parse('$baseUrl/studio/snapshot').replace(
      queryParameters: projectId == null ? null : {'projectId': projectId},
    );
    final response =
        await client.get(uri, headers: {'accept': 'application/json'});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException(
          'Studio snapshot failed (${response.statusCode})');
    }
    return StudioSnapshot.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response =
        await client.post(Uri.parse('$baseUrl/runs/$runId/$command'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Run control failed (${response.statusCode})');
    }
  }

  @override
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/goals'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'projectId': projectId,
        'objective': objective,
        'revision': revision,
        'commitSha': revision,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Goal creation failed (${response.statusCode})');
    }
  }

  @override
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/chats/$chatId/messages'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'content': text}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Send message failed (${response.statusCode})');
    }
    return StudioChatMessage.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/chats'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'title': title}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Create chat failed (${response.statusCode})');
    }
    return StudioChat.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
}

class DemoStudioDataSource implements StudioDataSource {
  const DemoStudioDataSource();
  @override
  Future<StudioSnapshot> loadSnapshot({String? projectId}) async =>
      StudioSnapshot.demo();

  @override
  Future<void> controlRun(String runId, String command) async {}

  @override
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  }) async {}

  @override
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  }) async {
    return StudioChatMessage(
      id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
      sender: StudioMessageSender.user,
      text: text,
      timestamp: 'Just now',
    );
  }

  @override
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  }) async {
    return StudioChat(
      id: 'chat-${DateTime.now().millisecondsSinceEpoch}',
      projectId: projectId,
      title: title,
      lastActivity: 'Just now',
      messages: [],
    );
  }
}

