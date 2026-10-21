part of '../ax_data.dart';

mixin _ThreadApi on _AxApiClientCore implements AxThreadReadDataSource {
  @override
  Future<List<AxThread>> loadSpaceThreads({
    required String spaceId,
  }) async {
    final body = await _getJson(Uri.parse('$baseUrl/spaces/$spaceId/threads'),
        conditional: true);
    final list = body['threads'];
    return (list as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxThread.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? idempotencyKey,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/spaces/$spaceId/threads'),
      headers: {
        ..._headers(contentType: 'application/json'),
        'Idempotency-Key': idempotencyKey ?? newAxIdempotencyKey()
      },
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
        'Thread creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final thread = body is Map ? (body['thread']) : null;
    if (thread is! Map) {
      throw const AxApiException('Thread creation response is malformed');
    }
    return AxThread.fromJson(Map<String, dynamic>.from(thread));
  }

  @override
  Future<void> markThreadRead(String threadId) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/read'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Marking Thread read failed',
          statusCode: response.statusCode);
    }
  }

  Future<void> setPinned(
      {required String kind, required String id, required bool pinned}) async {
    final uri = Uri.parse(
        '$baseUrl/pins/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(id)}');
    final response = pinned
        ? await client.put(uri, headers: _headers())
        : await client.delete(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Updating the pin failed',
          statusCode: response.statusCode);
    }
  }

  Future<void> setPinOrder(
      {required String kind,
      required List<String> ids,
      String? spaceId}) async {
    final response = await client.put(
      Uri.parse('$baseUrl/pins/order'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(
          {'kind': kind, 'ids': ids, if (spaceId != null) 'spaceId': spaceId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Reordering pins failed',
          statusCode: response.statusCode);
    }
  }

  Future<List<Map<String, dynamic>>> loadNotificationFeed() async {
    final body = await _getJson(Uri.parse('$baseUrl/notifications'));
    return (body['notifications'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> markNotificationsRead({List<String>? ids}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/notifications/read'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({if (ids != null) 'ids': ids}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Marking notifications read failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/threads/$threadId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (status != null) 'status': status,
        if (workConfig != null) 'workConfig': workConfig,
        if (metadata != null) 'metadata': metadata,
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
        'Thread update failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final thread = body is Map ? (body['thread']) : null;
    if (thread is! Map) {
      throw const AxApiException('Thread update response is malformed');
    }
    return AxThread.fromJson(Map<String, dynamic>.from(thread));
  }

  @override
  Future<void> deleteThread({required String threadId}) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/threads/$threadId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Thread deletion failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> clearThreadChatHistory({required String threadId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/chat/clear'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message for non-JSON responses.
      }
      throw AxApiException(
        'Clear chat history failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<String?> clearThreadWorkHistory({required String threadId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-history/clear'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message for non-JSON responses.
      }
      throw AxApiException(
        'Clear work history failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final cutoff = body is Map ? body['aiHistoryClearedAt'] : null;
    if (cutoff is! String || DateTime.tryParse(cutoff) == null) {
      throw const AxApiException('Malformed AI History cutoff');
    }
    return cutoff;
  }

  /// Uploads picked file bytes to Cloud storage and returns file references.
  /// Each picked map is updated in place with its `fileId`, so a retried
  /// submission reuses the upload and keeps the same idempotent request body.
  Future<List<Map<String, dynamic>>> _uploadWorkRequestFiles(
    String threadId,
    List<Map<String, dynamic>> attachments,
  ) async {
    final references = <Map<String, dynamic>>[];
    for (final attachment in attachments) {
      if (attachment['kind'] != 'file') {
        references.add(attachment);
        continue;
      }
      final uploadKey = jsonEncode([threadId, attachment]);
      var fileId = attachment['fileId'] is String
          ? attachment['fileId'] as String
          : _uploadedWorkFiles[uploadKey];
      if (fileId == null) {
        final encoded = attachment['contentBase64'];
        if (encoded is! String) {
          throw const AxApiException('Attached file content is missing');
        }
        final name = Uri.encodeQueryComponent(
            attachment['name']?.toString() ?? 'Attachment');
        final response = await client.post(
          Uri.parse('$baseUrl/threads/$threadId/work-request-files?name=$name'),
          headers: _headers(
              contentType: attachment['mediaType']?.toString() ??
                  'application/octet-stream'),
          body: base64Decode(encoded),
        );
        dynamic body;
        try {
          body = jsonDecode(response.body);
        } on FormatException {
          body = null;
        }
        final file = body is Map ? body['file'] : null;
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            file is! Map ||
            file['fileId'] is! String) {
          final detail = body is Map && body['error'] is String
              ? ': ${body['error']}'
              : '';
          throw AxApiException(
            'File upload failed (${response.statusCode})$detail',
            statusCode: response.statusCode,
          );
        }
        fileId = file['fileId'] as String;
        // Bound the in-memory cache; it is never persisted and clears on auth change.
        if (_uploadedWorkFiles.length >= 20) {
          _uploadedWorkFiles.remove(_uploadedWorkFiles.keys.first);
        }
        _uploadedWorkFiles[uploadKey] = fileId;
      }
      references.add({
        'kind': 'file',
        'name': attachment['name'],
        'mediaType': attachment['mediaType'],
        'sizeBytes': attachment['sizeBytes'],
        'fileId': fileId,
      });
    }
    return references;
  }

  @override
  Future<String> createWorkRequest({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
  }) async {
    final submissionId = idempotencyKey ?? newAxIdempotencyKey();
    AxWorkLatencyTrace.instance.submitted(submissionId);
    attachments = await _uploadWorkRequestFiles(threadId, attachments);
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests'),
      headers: {
        ..._headers(contentType: 'application/json'),
        'Idempotency-Key': submissionId
      },
      body: jsonEncode({
        'workflowId': workflowId,
        'input': {'originalRequest': prompt, 'attachments': attachments},
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      AxWorkLatencyTrace.instance.failed(submissionId);
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
      String detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on FormatException {
        /* Preserve status when the server returns no JSON. */
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    AxWorkLatencyTrace.instance.accepted(submissionId, request['id'] as String);
    return request['id'] as String;
  }

  @override
  Future<String> createWorkRequestWithSelection({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    String? idempotencyKey,
  }) async {
    final submissionId = idempotencyKey ?? newAxIdempotencyKey();
    AxWorkLatencyTrace.instance.submitted(submissionId);
    attachments = await _uploadWorkRequestFiles(threadId, attachments);
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests'),
      headers: {
        ..._headers(contentType: 'application/json'),
        'Idempotency-Key': submissionId
      },
      body: jsonEncode({
        'workflowId': workflowId,
        if (executionSelection.isNotEmpty)
          'executionSelection': executionSelection,
        'input': {'originalRequest': prompt, 'attachments': attachments},
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      AxWorkLatencyTrace.instance.failed(submissionId);
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on FormatException {
        /* Preserve status when the server returns no JSON. */
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    AxWorkLatencyTrace.instance.accepted(submissionId, request['id'] as String);
    return request['id'] as String;
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests/validate'),
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
      // The Cloud validator returns structured eligibility issues for 422.
      // Preserve those messages so the Work composer can tell the user what
      // needs to be fixed (for example, selecting a Workspace or restoring a
      // Worker grant) instead of reducing the response to a status code.
      if (decoded is Map && decoded['issues'] is List) {
        final messages = (decoded['issues'] as List)
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .where((message) => message.trim().isNotEmpty)
            .toList(growable: false);
        if (messages.isNotEmpty) return messages;
      }
      throw AxApiException(
        _eligibilityFailureMessage(response.statusCode, decoded),
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
  Future<List<String>> validateWorkRequestEligibilityWithSelection({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests/validate'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        if (executionSelection.isNotEmpty)
          'executionSelection': executionSelection,
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
      if (decoded is Map && decoded['issues'] is List) {
        final messages = (decoded['issues'] as List)
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .where((message) => message.trim().isNotEmpty)
            .toList(growable: false);
        if (messages.isNotEmpty) return messages;
      }
      throw AxApiException(
          _eligibilityFailureMessage(response.statusCode, decoded),
          statusCode: response.statusCode);
    }
    final issues = decoded is Map ? decoded['issues'] : null;
    return issues is List
        ? issues
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .toList(growable: false)
        : const [];
  }

  @override
  Future<AxConversationHistoryPage> loadConversationHistory(
      {required String threadId,
      required String conversationId,
      int afterSequence = 0,
      int? throughSequence,
      int limit = 50}) async {
    final uri = Uri.parse(
            '$baseUrl/threads/${Uri.encodeComponent(threadId)}/conversations/${Uri.encodeComponent(conversationId)}/history')
        .replace(queryParameters: {
      'afterSequence': '$afterSequence',
      'limit': '$limit',
      if (throughSequence != null) 'throughSequence': '$throughSequence',
    });
    final body = await _getJson(uri);
    final page = AxConversationHistoryPage.fromJson(body);
    if (page.conversationId != conversationId) {
      throw const AxApiException('Malformed Conversation history scope');
    }
    return page;
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
    final activityHistory = (requestMap['activities'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    if (requestMap['id'] != workRequestId || requestMap['status'] is! String) {
      throw const AxApiException('Malformed Work Request detail');
    }
    return AxWorkRequestStatus(
      id: requestMap['id'] as String,
      conversationId: requestMap['conversationId'] as String?,
      workflowRun: requestMap['workflowRun'] is Map
          ? AxWorkflowRun.fromJson(
              Map<String, dynamic>.from(requestMap['workflowRun'] as Map))
          : null,
      turns: List.unmodifiable((requestMap['turns'] as List? ?? const [])
          .whereType<Map>()
          .map((item) =>
              AxConversationTurn.fromJson(Map<String, dynamic>.from(item)))),
      executionConfig: requestMap['executionConfig'] is Map
          ? AxTurnExecutionConfig.fromJson(
              Map<String, dynamic>.from(requestMap['executionConfig'] as Map))
          : null,
      threadId: (requestMap['threadId']) as String?,
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
      attachments: AxWorkAttachment.fromList(requestMap['attachments']),
      createdAt: requestMap['createdAt']?.toString(),
      steps: steps,
      activityHistory: activityHistory,
      executionPhase: requestMap['executionPhase']?.toString(),
    );
  }

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
    bool clearAiHistory = false,
    bool confirmSideEffects = false,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/retry'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'stepKind': stepKind,
        if (sessionStrategy != null) 'sessionStrategy': sessionStrategy,
        if (confirmSideEffects) 'confirmSideEffects': true,
        if (clearAiHistory) 'clearAiHistory': true,
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
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async {
    final uri = Uri.parse('$baseUrl/issue-reports').replace(queryParameters: {
      'requestId': requestId,
      if (assignmentId != null && assignmentId.isNotEmpty)
        'assignmentId': assignmentId,
    });
    final body = await _getJson(uri);
    final report = body['report'];
    return report is Map
        ? AxIssueReport.fromJson(Map<String, dynamic>.from(report))
        : null;
  }

  @override
  Future<AxIssueReport> reportIssue({required String requestId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/issue-reports'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'requestId': requestId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        "Couldn't send the report. Try again.",
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    final report = decoded is Map ? decoded['report'] : null;
    if (report is! Map) {
      throw const AxApiException('Issue report response is malformed');
    }
    return AxIssueReport.fromJson(Map<String, dynamic>.from(report));
  }

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
      {required String threadId,
      int limit = 50,
      String? beforeCreatedAt,
      String? beforeId,
      bool activeOnly = false}) async {
    if (limit < 1 ||
        limit > 100 ||
        (beforeCreatedAt == null) != (beforeId == null) ||
        beforeCreatedAt == '' ||
        beforeId == '') {
      throw ArgumentError('Invalid Work history page parameters');
    }
    final uri = Uri.parse('$baseUrl/threads/$threadId/work-requests')
        .replace(queryParameters: {
      'limit': '$limit',
      if (activeOnly) 'activeOnly': 'true',
      if (beforeCreatedAt != null) 'beforeCreatedAt': beforeCreatedAt,
      if (beforeId != null) 'beforeId': beforeId,
    });
    final body = await _getJson(uri);
    final raw = body['workRequests'];
    final cursor = body['nextCursor'];
    if (raw is! List ||
        raw.any((v) => v is! Map) ||
        (cursor != null &&
            (cursor is! Map ||
                cursor['createdAt'] is! String ||
                cursor['id'] is! String ||
                cursor['createdAt'] == '' ||
                cursor['id'] == ''))) {
      throw const AxApiException('Malformed Work history page');
    }
    final records = raw
        .map((v) => AxWorkRequest.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (records.any((v) => v.id.isEmpty || v.createdAt.isEmpty)) {
      throw const AxApiException('Malformed Work Request');
    }
    final clearedAt = body['aiHistoryClearedAt'];
    return AxWorkRequestPage(
        aiHistoryClearedAt: clearedAt is String ? clearedAt : null,
        requests: records.reversed,
        nextCursor: cursor == null
            ? null
            : AxWorkRequestCursor(
                createdAt: cursor['createdAt'] as String,
                id: cursor['id'] as String));
  }

  @override
  Future<AxDiscussionPage> loadDiscussionPage(
      {required String threadId,
      int limit = 50,
      String? before,
      String? after}) async {
    if (limit < 1 || limit > 100 || (before != null && after != null)) {
      throw ArgumentError('Invalid Discussion page parameters');
    }
    final uri = Uri.parse('$baseUrl/threads/$threadId/discussion-messages')
        .replace(queryParameters: {
      'limit': '$limit',
      if (before != null) 'before': before,
      if (after != null) 'after': after
    });
    final body = await _getJson(uri);
    if (body['schemaVersion'] != 1 ||
        body['messages'] is! List ||
        (body['nextCursor'] != null && body['nextCursor'] is! String) ||
        (body['newestCursor'] != null && body['newestCursor'] is! String)) {
      final invalid = <String>[
        if (body['schemaVersion'] != 1)
          'expected schemaVersion 1, received ${body['schemaVersion'] ?? "missing"}',
        if (body['messages'] is! List) 'messages must be a list',
        if (body['nextCursor'] != null && body['nextCursor'] is! String)
          'nextCursor must be a string or null',
        if (body['newestCursor'] != null && body['newestCursor'] is! String)
          'newestCursor must be a string or null',
      ];
      throw AxApiException(
          'Discussion page response is malformed: ${invalid.join("; ")}');
    }
    final messages = (body['messages'] as List).map((item) {
      if (item is! Map) {
        throw const AxApiException('Discussion message is malformed');
      }
      final message =
          AxDiscussionMessage.fromJson(Map<String, dynamic>.from(item));
      if (message.id.isEmpty || message.threadId != threadId) {
        throw const AxApiException(
            'Discussion message identity does not match');
      }
      return message;
    });
    return AxDiscussionPage(
        messages: messages,
        nextCursor: body['nextCursor'] as String?,
        newestCursor: body['newestCursor'] as String?);
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String threadId,
    required String text,
    List<String> references = const [],
    String? idempotencyKey,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/discussion-messages'),
      headers: {
        ..._headers(contentType: 'application/json'),
        'Idempotency-Key': idempotencyKey ?? newAxIdempotencyKey()
      },
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
  Future<AxDiscussionMessage> loadDiscussionMessage(
      {required String messageId}) async {
    final response = await client.get(
        Uri.parse(
            '$baseUrl/discussion-messages/${Uri.encodeComponent(messageId)}'),
        headers: _headers());
    if (response.statusCode != 200) {
      throw AxApiException(
          'Discussion message loading failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map || message['id'] != messageId) {
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
  Future<void> deleteDiscussionMessage({
    required String messageId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/discussion-messages/$messageId'),
      headers: _headers(),
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
        'Discussion message delete failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async {
    // Members also receive the Workers their Workspace owner shares with them.
    final body =
        await _getJson(Uri.parse('$baseUrl/workers?includeShared=true'));
    return (body['workers'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorker.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }
}

/// A 422 eligibility error reads like `implement: Select a Worker ...`; users
/// only need the final sentence. Other failures keep the status prefix.
String _eligibilityFailureMessage(int statusCode, Object? decoded) {
  final error = decoded is Map && decoded['error'] is String
      ? (decoded['error'] as String).trim()
      : '';
  if (statusCode == 422 && error.isNotEmpty) {
    return error.substring(error.lastIndexOf(': ') + 1).trim();
  }
  return 'Work eligibility check failed ($statusCode)'
      '${error.isEmpty ? '' : ': $error'}';
}
