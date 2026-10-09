part of '../ax_data.dart';

mixin _AuthApi on _AxApiClientCore {
  @override
  Future<AxSession> loadSession() async {
    final response =
        await client.get(Uri.parse('$baseUrl/session'), headers: _headers());
    if (response.statusCode == 401) {
      _bindReadUser(null);
      return const AxSession(authenticated: false);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final session =
        AxSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    _bindReadUser(session.authenticated ? session.viewer?.id : null);
    return session;
  }

  @override
  Future<List<int>?> loadAvatar({required String url}) async {
    final response = await client.get(Uri.parse(url), headers: _headers());
    if (response.statusCode == 404 || response.statusCode == 401) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Avatar lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  @override
  Future<void> updateDisplayName({required String displayName}) =>
      _postAuth('/auth/update-user', {'name': displayName});

  @override
  Future<AxEmailChangeResult> requestEmailChange(
      {required String email}) async {
    final callbackURL = Uri.base.scheme == 'http' || Uri.base.scheme == 'https'
        ? '${Uri.base.origin}/settings/profile'
        : '/settings/profile';
    final response = await client.post(
      Uri.parse('$baseUrl/auth/change-email'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'newEmail': email,
        'callbackURL': callbackURL,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Email update failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['message'] is String) {
          message = decoded['message'] as String;
        } else if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    final message = decoded is Map && decoded['message'] is String
        ? decoded['message'] as String
        : null;
    return AxEmailChangeResult(
      message: message,
      verificationRequired: message == 'Verification email sent',
    );
  }

  @override
  Future<void> logout() async {
    clearConditionalReads();
    final response = await client.post(Uri.parse('$baseUrl/auth/sign-out'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(const <String, dynamic>{}));
    clearConditionalReads();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Logout failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    sessionToken = null;
  }

  @override
  Future<String> uploadAvatar({
    required List<int> bytes,
    required String mediaType,
  }) async {
    final response = await client.put(
      Uri.parse('$baseUrl/profile/avatar'),
      headers: _headers(contentType: mediaType),
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Avatar upload failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    final url = decoded is Map ? decoded['avatarUrl'] : null;
    if (url is! String || url.isEmpty) {
      throw const AxApiException('Avatar upload response is malformed');
    }
    return url;
  }

  Future<void> _postAuth(String path, Map<String, dynamic> body) async {
    final response = await client.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Authentication request failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['message'] is String) {
          message = decoded['message'] as String;
        } else if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } catch (_) {
        // Keep the status-based message for non-JSON responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        if (decoded['token'] is String) {
          sessionToken = decoded['token'] as String;
        } else if (decoded['session'] is Map &&
            decoded['session']['token'] is String) {
          sessionToken = decoded['session']['token'] as String;
        }
      }
    } catch (_) {
      // Non-JSON response
    }
    try {
      final setCookie = response.headers['set-cookie'];
      if (setCookie != null &&
          (sessionToken == null || sessionToken!.isEmpty)) {
        final match = RegExp(
                r'(?:better-auth\.session_token|__Secure-better-auth\.session_token)=([^;]+)')
            .firstMatch(setCookie);
        if (match != null) {
          sessionToken = match.group(1);
        }
      }
    } catch (_) {
      // Ignored
    }
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) =>
      _postAuth('/auth/sign-in/email', {
        'email': email,
        'password': password,
      });

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) =>
      _postAuth('/auth/sign-up/email', {
        'name': name,
        'email': email,
        'password': password,
      });

  @override
  Future<void> requestPasswordReset({required String email}) => _postAuth(
        '/auth/request-password-reset',
        {
          'email': email,
          'redirectTo': '${Uri.base.origin}/login',
        },
      );

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) =>
      _postAuth('/auth/reset-password', {
        'token': token,
        'newPassword': password,
      });

  @override
  Future<AxAccountSecurity> loadAccountSecurity() async {
    final responses = await Future.wait([
      client.get(Uri.parse('$baseUrl/auth/list-accounts'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/list-sessions'), headers: _headers()),
    ]);
    for (final response in responses) {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AxApiException(
            'Account security lookup failed (${response.statusCode})',
            statusCode: response.statusCode);
      }
    }
    final accountsBody = jsonDecode(responses[0].body);
    final sessionsBody = jsonDecode(responses[1].body);
    final accounts = accountsBody is List
        ? accountsBody
        : accountsBody is Map && accountsBody['accounts'] is List
            ? accountsBody['accounts'] as List
            : const [];
    final sessions = sessionsBody is List
        ? sessionsBody
        : sessionsBody is Map && sessionsBody['sessions'] is List
            ? sessionsBody['sessions'] as List
            : const [];
    return AxAccountSecurity.fromJson(
      accounts
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
      sessions
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
    );
  }

  @override
  Future<void> approveDesktopAuthIntent({
    required String intentId,
  }) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/approve'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Desktop sign-in approval failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON error responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
  }

  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus({
    required String intentId,
  }) async {
    final body = await _getJson(Uri.parse(
      '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/browser-status',
    ));
    try {
      return AxDesktopAuthIntentStatus.fromJson(body);
    } on FormatException {
      throw const AxApiException('Sign-in request metadata is malformed');
    }
  }

  @override
  Future<void> denyDesktopAuthIntent({required String intentId}) async {
    final response = await client.post(
      Uri.parse(
        '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/deny',
      ),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Sign-in cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> revokeAccountSession(String token) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/revoke-session'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session revocation failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/link-social'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'provider': provider,
        'callbackURL': returnTo.toString(),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Could not start account linking',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final url = body is Map ? body['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const AxApiException('Account linking response is malformed');
    }
    return Uri.parse(url);
  }
}
