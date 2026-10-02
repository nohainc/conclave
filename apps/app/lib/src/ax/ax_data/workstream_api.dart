part of '../ax_data.dart';

mixin _WorkstreamApi on _AxApiClientCore {
  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams({
    required String projectId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/projects/$projectId/workstreams'));
    return (body['workstreams'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkstream.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxWorkstream> createWorkstream({
    required String projectId,
    required String name,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/projects/$projectId/workstreams'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Workstream creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final workstream = body is Map ? body['workstream'] : null;
    if (workstream is! Map) {
      throw const AxApiException('Workstream creation response is malformed');
    }
    return AxWorkstream.fromJson(Map<String, dynamic>.from(workstream));
  }

  @override
  Future<AxWorkstream> updateWorkstream({
    required String workstreamId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workstreams/$workstreamId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (status != null) 'status': status,
        if (workConfig != null) 'workConfig': workConfig,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Workstream update failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final workstream = body is Map ? body['workstream'] : null;
    if (workstream is! Map) {
      throw const AxApiException('Workstream update response is malformed');
    }
    return AxWorkstream.fromJson(Map<String, dynamic>.from(workstream));
  }

  @override
  Future<void> deleteWorkstream({required String workstreamId}) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/workstreams/$workstreamId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Workstream deletion failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<String> createWorkRequest({
    required String workstreamId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        'input': {'originalRequest': prompt, 'attachments': attachments},
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 422) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['issues'] is List) {
            final name = body['workflowName']?.toString() ?? workflowId;
            final messages = (body['issues'] as List)
                .whereType<Map>()
                .map((issue) => issue['message'])
                .whereType<String>()
                .toList(growable: false);
            if (messages.isNotEmpty) {
              throw AxApiException(
                'Cannot run $name\n${messages.map((message) => '• $message').join('\n')}',
                statusCode: 422,
              );
            }
          }
        } on AxApiException {
          rethrow;
        } on FormatException {
          // Fall through to the status-only error below.
        }
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    return request['id'] as String;
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String workstreamId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests/validate'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        'attachments': attachments
            .map((attachment) => {
                  'kind': attachment['kind'],
                  'mediaType': attachment['mediaType'],
                })
            .toList(growable: false),
      }),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const AxApiException('Work eligibility response is malformed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Work eligibility check failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw const AxApiException('Work eligibility response is malformed');
    }
    final issues = decoded['issues'];
    if (issues is! List) return const [];
    return issues
        .whereType<Map>()
        .map((issue) => issue['message'])
        .whereType<String>()
        .toList(growable: false);
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/work-requests/$workRequestId'));
    final request = body['workRequest'];
    final result = body['result'];
    final resultMap = result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
    final requestMap = request is Map
        ? Map<String, dynamic>.from(request)
        : const <String, dynamic>{};
    final steps = (body['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkRequestStep.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
    return AxWorkRequestStatus(
      status: requestMap['status']?.toString() ?? 'unknown',
      text: resultMap['text']?.toString(),
      errorCode: body['errorCode']?.toString(),
      errorMessage: body['errorMessage']?.toString(),
      error: body['errorCode'] is String
          ? 'Run failed (${body['errorCode']}).'
          : null,
      workflowId: requestMap['workflowId']?.toString(),
      workflowVersion: requestMap['workflowVersion'] as int?,
      workflowName: requestMap['workflowName']?.toString(),
      requestedByUserId: requestMap['requestedByUserId']?.toString(),
      requestedByName: requestMap['requestedByName']?.toString(),
      originalRequest: requestMap['originalRequest']?.toString(),
      createdAt: requestMap['createdAt']?.toString(),
      steps: steps,
    );
  }

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/retry'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'stepKind': stepKind,
        if (sessionStrategy != null) 'sessionStrategy': sessionStrategy,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Step retry failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/cancel'),
      headers: _headers(contentType: 'application/json'),
      body: '{}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Run cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxWorkRequest>> loadWorkstreamWorkRequests({
    required String workstreamId,
    bool activeOnly = false,
  }) async {
    const pageSize = 100;
    final records = <AxWorkRequest>[];
    String? beforeCreatedAt;
    String? beforeId;
    while (true) {
      final uri = Uri.parse('$baseUrl/workstreams/$workstreamId/work-requests')
          .replace(queryParameters: {
        'limit': '$pageSize',
        if (activeOnly) 'activeOnly': 'true',
        if (beforeCreatedAt != null) 'beforeCreatedAt': beforeCreatedAt,
        if (beforeId != null) 'beforeId': beforeId,
      });
      final body = await _getJson(uri);
      final page = (body['workRequests'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AxWorkRequest.fromJson(
                Map<String, dynamic>.from(item),
              ))
          .toList();
      records.addAll(page);
      final cursor = body['nextCursor'];
      if (cursor is! Map ||
          cursor['createdAt'] is! String ||
          cursor['id'] is! String) {
        break;
      }
      beforeCreatedAt = cursor['createdAt'] as String;
      beforeId = cursor['id'] as String;
    }
    return records.reversed.toList();
  }

  @override
  Future<List<AxDiscussionMessage>> loadDiscussionMessages({
    required String workstreamId,
  }) async {
    final body = await _getJson(
      Uri.parse('$baseUrl/workstreams/$workstreamId/discussion-messages'),
    );
    return (body['messages'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxDiscussionMessage.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList();
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String workstreamId,
    required String text,
    List<String> references = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/workstreams/$workstreamId/discussion-messages'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'body': text,
        'references': references,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message submission failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException('Discussion message response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/discussion-messages/$messageId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'body': text,
        'references': references,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message edit failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException(
          'Discussion message edit response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async {
    final body = await _getJson(Uri.parse('$baseUrl/workers'));
    return (body['workers'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorker.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }
}
