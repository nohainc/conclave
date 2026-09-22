import 'dart:convert';

import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';

class _JsonClient extends http.BaseClient {
  _JsonClient(this.body);

  final Map<String, dynamic> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      201,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('normalizes the Cloud chat message envelope', () async {
    final client = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: _JsonClient({
        'message': {
          'id': 'message-1',
          'senderType': 'user',
          'content': 'Fix the bug',
          'createdAt': '2026-09-22T00:00:00Z',
          'metadata': {},
        },
      }),
    );

    final message = await client.sendChatMessage(
      projectId: 'project-1',
      chatId: 'chat-1',
      text: 'Fix the bug',
    );

    expect(message.sender, StudioMessageSender.user);
    expect(message.text, 'Fix the bug');
  });

  test('normalizes the Cloud chat creation wrapper', () async {
    final client = StudioApiClient(
      baseUrl: 'https://conclave.test/api',
      client: _JsonClient({
        'chat': {
          'id': 'chat-1',
          'projectId': 'project-1',
          'title': 'Auth',
          'status': 'active',
          'updatedAt': '2026-09-22T00:00:00Z',
        },
      }),
    );

    final chat = await client.createChat(
      projectId: 'project-1',
      title: 'Auth',
    );

    expect(chat.id, 'chat-1');
    expect(chat.lastActivity, '2026-09-22T00:00:00Z');
  });
}
