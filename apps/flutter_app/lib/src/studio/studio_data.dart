import 'dart:convert';

import 'package:http/http.dart' as http;

import 'studio_models.dart';

abstract interface class StudioDataSource {
  Future<StudioSnapshot> loadSnapshot({String? projectId});
  Future<void> controlRun(String runId, String command);
}

class StudioApiException implements Exception {
  const StudioApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StudioApiClient implements StudioDataSource {
  StudioApiClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? const String.fromEnvironment(
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
    final response = await client.get(uri, headers: {'accept': 'application/json'});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Studio snapshot failed (${response.statusCode})');
    }
    return StudioSnapshot.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> controlRun(String runId, String command) async {
    final response = await client.post(Uri.parse('$baseUrl/runs/$runId/$command'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StudioApiException('Run control failed (${response.statusCode})');
    }
  }
}

class DemoStudioDataSource implements StudioDataSource {
  const DemoStudioDataSource();
  @override
  Future<StudioSnapshot> loadSnapshot({String? projectId}) async => StudioSnapshot.demo();

  @override
  Future<void> controlRun(String runId, String command) async {}
}
