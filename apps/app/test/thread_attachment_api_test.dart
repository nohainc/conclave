import 'dart:convert';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
      'discussion uploads authenticated thumbnails once and retries stable references',
      () async {
    var uploads = 0;
    final sent = <Map<String, dynamic>>[];
    final source = AxApiClient(
        baseUrl: 'https://cloud.test',
        client: MockClient((request) async {
          if (request.url.path.endsWith('work-request-files')) {
            uploads++;
            expect(request.url.queryParameters['purpose'], 'discussion');
            expect(request.headers['content-type'],
                startsWith('multipart/form-data'));
            expect(request.body, contains('previewImage'));
            expect(request.body, contains('/9j/AAAA'));
            return http.Response(
                jsonEncode({
                  'file': {'fileId': 'wrf-test'}
                }),
                201);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          sent.add(body);
          expect(request.headers['Idempotency-Key'], 'retry-key');
          return http.Response(
              jsonEncode({
                'message': {
                  'id': 'saved',
                  'threadId': 'thread',
                  'authorUserId': 'owner',
                  'body': '',
                  'createdAt': 'now',
                  'attachments': [
                    {
                      'kind': 'file',
                      'fileId': 'wrf-test',
                      'name': 'photo.jpg',
                      'sizeBytes': 4,
                      'previewImage': '/9j/AAAA'
                    }
                  ]
                }
              }),
              201);
        }));
    final files = [
      {
        'kind': 'file',
        'name': 'photo.jpg',
        'sizeBytes': 4,
        'mediaType': 'image/jpeg',
        'contentBase64': base64Encode([1, 2, 3, 4]),
        'previewImage': '/9j/AAAA'
      }
    ];
    final saved = await source.sendDiscussionMessage(
        threadId: 'thread',
        text: '',
        attachments: files,
        idempotencyKey: 'retry-key');
    await source.sendDiscussionMessage(
        threadId: 'thread',
        text: '',
        attachments: files,
        idempotencyKey: 'retry-key');
    expect(uploads, 1);
    expect(sent.first, sent.last);
    expect((sent.first['attachments'] as List).single,
        isNot(contains('contentBase64')));
    expect(saved.attachments.single['previewImage'], '/9j/AAAA');
  });
}
