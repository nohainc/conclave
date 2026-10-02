part of '../ax_data.dart';

mixin _AuthApi on _AxApiClientCore {
  @override
  Future<AxSession> loadSession() async {
    final response =
        await client.get(Uri.parse('$baseUrl/session'), headers: _headers());
    if (response.statusCode == 401) {
      return const AxSession(authenticated: false);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return AxSession.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  @override
  Future<void> logout() async {
    sessionToken = null;
    final response = await client.post(Uri.parse('$baseUrl/auth/sign-out'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Logout failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
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
      client.get(Uri.parse('$baseUrl/auth/passkey/list-user-passkeys'),
          headers: _headers()),
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
    final passkeysBody = jsonDecode(responses[2].body);
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
    final passkeys = passkeysBody is List
        ? passkeysBody
        : passkeysBody is Map && passkeysBody['passkeys'] is List
            ? passkeysBody['passkeys'] as List
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
      passkeys
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
    );
  }

  @override
  Future<void> registerPasskey(String name) async {
    await passkeyBrowser.register(baseUrl, name);
  }

  @override
  Future<void> deletePasskey(String id) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/passkey/delete-passkey'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'id': id}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Passkey removal failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> signInWithPasskey() async {
    await passkeyBrowser.signIn(baseUrl);
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
      var message =
          'Workspace sign-in approval failed (${response.statusCode})';
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
  Future<String> loadDesktopAuthIntentStatus({
    required String intentId,
  }) async {
    final body = await _getJson(Uri.parse(
      '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/browser-status',
    ));
    final status = body['status'];
    if (status is! String) {
      throw const AxApiException('Sign-in request status is malformed');
    }
    return status;
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
