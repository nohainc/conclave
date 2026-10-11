import 'dart:convert';

import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('issue reporting submits only the failed request reference', () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/issue-reports');
        expect(jsonDecode(request.body), {'requestId': 'request-1'});
        return http.Response(
          jsonEncode({
            'report': {
              'id': 'issue-1',
              'publicReference': 'ISS-1',
              'status': 'open',
              'diagnosticState': 'partial',
              'createdAt': '2026-10-11T00:00:00Z',
              'updatedAt': '2026-10-11T00:00:00Z',
            }
          }),
          201,
        );
      }),
    );
    final report = await api.reportIssue(requestId: 'request-1');
    expect(report.publicReference, 'ISS-1');
    expect(report.diagnosticState, 'partial');
  });

  test('issue report status can be restored for a failed assignment', () async {
    final api = AxApiClient(
      baseUrl: 'https://app.example/api',
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {
          'requestId': 'request-1',
          'assignmentId': 'assignment-1',
        });
        return http.Response(
          jsonEncode({
            'report': {
              'id': 'issue-1',
              'publicReference': 'ISS-1',
              'status': 'open',
              'diagnosticState': 'partial',
              'createdAt': '2026-10-11T00:00:00Z',
              'updatedAt': '2026-10-11T00:00:00Z',
            }
          }),
          200,
        );
      }),
    );
    final report = await api.loadIssueReport(
      requestId: 'request-1',
      assignmentId: 'assignment-1',
    );
    expect(report?.id, 'issue-1');
  });
}
