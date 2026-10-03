import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile_lab_cloud_config.dart';

const profileLabAudience = 'conclave.profile-lab.management';
const profileLabClientName = 'Conclave Profile Lab';
const profileLabAuthIntentContractVersion = '1.1';

/// A verified, signed-in human session scoped exclusively to Profile Lab management.
class ProfileLabSession {
  const ProfileLabSession({
    required this.credential,
    required this.sessionId,
    required this.userId,
    required this.displayName,
    required this.email,
    required this.expiresAt,
    this.audience = profileLabAudience,
    this.issuedAt,
  });

  final String credential;
  final String sessionId;
  final String userId;
  final String displayName;
  final String email;
  final String audience;
  final DateTime expiresAt;
  final DateTime? issuedAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  factory ProfileLabSession.fromJson(Map<String, dynamic> json) {
    final audienceVal = json['audience'];
    if (audienceVal != profileLabAudience) {
      throw FormatException(
        'Session audience "$audienceVal" does not match required "$profileLabAudience"',
      );
    }
    final user = json['user'];
    if (user is! Map) {
      throw const FormatException('Profile Lab session user object is missing');
    }

    String required(Object? value, String field) {
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Profile Lab session is missing $field');
      }
      return value.trim();
    }

    return ProfileLabSession(
      credential: required(json['credential'], 'credential'),
      sessionId: required(json['sessionId'], 'sessionId'),
      userId: required(user['userId'], 'userId'),
      displayName: required(user['displayName'], 'displayName'),
      email: required(user['email'], 'email'),
      audience: profileLabAudience,
      expiresAt: DateTime.parse(required(json['expiresAt'], 'expiresAt')),
      issuedAt: DateTime.tryParse(json['issuedAt']?.toString() ?? ''),
    );
  }

  factory ProfileLabSession.fromStoredJson(Map<String, dynamic> json) {
    final audienceVal = json['audience'];
    if (audienceVal != profileLabAudience) {
      throw FormatException(
        'Stored session audience "$audienceVal" does not match required "$profileLabAudience"',
      );
    }

    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Stored Profile Lab session is missing $key');
      }
      return value.trim();
    }

    return ProfileLabSession(
      credential: required('credential'),
      sessionId: required('sessionId'),
      userId: required('userId'),
      displayName: required('displayName'),
      email: required('email'),
      audience: profileLabAudience,
      expiresAt: DateTime.parse(required('expiresAt')),
      issuedAt: DateTime.tryParse(json['issuedAt']?.toString() ?? ''),
    );
  }

  Map<String, Object?> toStoredJson() => {
        'credential': credential,
        'sessionId': sessionId,
        'userId': userId,
        'displayName': displayName,
        'email': email,
        'audience': audience,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        if (issuedAt != null) 'issuedAt': issuedAt!.toUtc().toIso8601String(),
      };
}

/// An initiated browser-assisted authentication intent for Profile Lab.
class ProfileLabAuthIntent {
  const ProfileLabAuthIntent({
    required this.intentId,
    required this.pollToken,
    required this.verificationUrl,
    required this.expiresAt,
    required this.pollIntervalMs,
    required this.audience,
  });

  final String intentId;
  final String pollToken;
  final Uri verificationUrl;
  final DateTime expiresAt;
  final int pollIntervalMs;
  final String audience;

  factory ProfileLabAuthIntent.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Profile Lab sign-in response is missing $key');
      }
      return value.trim();
    }

    final url = Uri.tryParse(required('verificationUrl'));
    var secureOrigin = false;
    if (url != null && url.host.isNotEmpty && url.userInfo.isEmpty) {
      try {
        ProfileLabCloudConfig.normalizeOrigin(url.origin);
        secureOrigin = true;
      } on ArgumentError {
        secureOrigin = false;
      }
    }
    if (url == null || !secureOrigin) {
      throw const FormatException(
        'Profile Lab sign-in verification URL is invalid',
      );
    }
    final aud = json['audience']?.toString().trim();
    if (aud != null && aud.isNotEmpty && aud != profileLabAudience) {
      throw FormatException('Intent audience "$aud" is not supported');
    }
    return ProfileLabAuthIntent(
      intentId: required('intentId'),
      pollToken: required('pollToken'),
      verificationUrl: url,
      expiresAt: DateTime.parse(required('expiresAt')),
      pollIntervalMs:
          json['pollIntervalMs'] is int ? json['pollIntervalMs'] as int : 2000,
      audience: profileLabAudience,
    );
  }
}

/// Client handling Profile Lab browser-assisted human authentication ceremonies.
class ProfileLabAuthClient {
  ProfileLabAuthClient({
    required String cloudUrl,
    HttpClient? httpClient,
  })  : _cloudOrigin =
            Uri.parse(ProfileLabCloudConfig.normalizeOrigin(cloudUrl)),
        _http = httpClient ?? HttpClient();

  final Uri _cloudOrigin;
  final HttpClient _http;

  Uri _api(String path) => _cloudOrigin.replace(path: '/api$path');

  Future<Map<String, dynamic>> _requestJson(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    String? bearer,
  }) async {
    final request =
        await (method == 'GET' ? _http.getUrl(uri) : _http.postUrl(uri))
            .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 20));
    Map<String, dynamic> decoded = const {};
    try {
      final value = jsonDecode(text);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on Object {
      // Error response text is intentionally not treated as structured diagnostics.
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded['error'] is String
          ? decoded['error'] as String
          : 'Profile Lab cloud authentication failed (HTTP ${response.statusCode})';
      throw StateError(message);
    }
    return decoded;
  }

  /// Initiates a desktop auth intent bound to the Profile Lab audience.
  Future<ProfileLabAuthIntent> createIntent() async {
    final json = await _requestJson(
      'POST',
      _api('/desktop-auth/intents'),
      body: {
        'clientName': profileLabClientName,
        'contractVersion': profileLabAuthIntentContractVersion,
        'audience': profileLabAudience,
      },
    );
    final intent = ProfileLabAuthIntent.fromJson(json);
    if (intent.verificationUrl.origin != _cloudOrigin.origin) {
      throw const FormatException(
        'Profile Lab sign-in URL does not match configured Cloud origin',
      );
    }
    return intent;
  }

  /// Opens the system browser for human sign-in approval.
  Future<void> openVerification(ProfileLabAuthIntent intent) async {
    final url = intent.verificationUrl.toString();
    final command = switch (Platform.operatingSystem) {
      'macos' => ('open', [url]),
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      'linux' => ('xdg-open', [url]),
      _ => throw UnsupportedError(
          'Opening system browser is not supported on this platform.',
        ),
    };
    await Process.start(
      command.$1,
      command.$2,
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
  }

  /// Cancels an in-progress authentication intent.
  Future<void> cancelIntent(ProfileLabAuthIntent intent) async {
    await _requestJson(
      'POST',
      _api(
          '/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}/cancel'),
      bearer: intent.pollToken,
      body: const <String, Object?>{},
    );
  }

  /// Polls the Cloud intent until approved, then exchanges for a ProfileLabSession.
  Future<ProfileLabSession> waitForApprovalAndClaim(
    ProfileLabAuthIntent intent, {
    bool Function()? isCancelled,
  }) async {
    while (DateTime.now().toUtc().isBefore(intent.expiresAt.toUtc())) {
      if (isCancelled?.call() ?? false) {
        throw StateError('Profile Lab sign-in was cancelled.');
      }
      final status = await _requestJson(
        'GET',
        _api('/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}'),
        bearer: intent.pollToken,
      );
      switch (status['status']) {
        case 'approved':
          final response = await _requestJson(
            'POST',
            _api(
                '/desktop-auth/intents/${Uri.encodeComponent(intent.intentId)}/claim'),
            body: {'pollToken': intent.pollToken},
          );
          return ProfileLabSession.fromJson(response);
        case 'denied':
          throw StateError('This Conclave Profile Lab sign-in was denied.');
        case 'expired':
        case 'claimed':
          throw StateError(
            'This Conclave Profile Lab sign-in request is no longer available.',
          );
        case 'pending':
          final waitUntil = DateTime.now().add(
            Duration(milliseconds: intent.pollIntervalMs.clamp(1000, 10000)),
          );
          while (DateTime.now().isBefore(waitUntil)) {
            if (isCancelled?.call() ?? false) {
              throw StateError('Profile Lab sign-in was cancelled.');
            }
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
      }
    }
    throw StateError(
        'This Profile Lab sign-in request expired. Start sign-in again.');
  }

  /// Validates the current session against Cloud.
  Future<void> validateSession(ProfileLabSession session) async {
    final result = await _requestJson(
      'GET',
      _api('/desktop-auth/session'),
      bearer: session.credential,
    );
    final user = result['user'];
    if (result['sessionId'] != session.sessionId ||
        result['audience'] != profileLabAudience ||
        user is! Map ||
        user['userId'] != session.userId) {
      throw const FormatException(
        'Cloud did not confirm the Profile Lab management session',
      );
    }
  }

  /// Binds a recent browser-completed passkey ceremony to this Profile Lab
  /// session so Cloud can authorize a sensitive release operation.
  Future<void> completeStepUp(ProfileLabSession session) async {
    await _requestJson(
      'POST',
      _api('/desktop-auth/profile-lab/step-up/complete'),
      bearer: session.credential,
      body: const <String, Object?>{},
    );
  }

  /// Rotates an existing session credential.
  Future<ProfileLabSession> rotateSession(ProfileLabSession session) async {
    final response = await _requestJson(
      'POST',
      _api(
          '/desktop-auth/sessions/${Uri.encodeComponent(session.sessionId)}/rotate'),
      bearer: session.credential,
      body: const <String, Object?>{},
    );
    final rotated = ProfileLabSession.fromJson(response);
    if (rotated.sessionId != session.sessionId ||
        rotated.userId != session.userId) {
      throw const FormatException(
        'Cloud rotated the Profile Lab session to a different account',
      );
    }
    return rotated;
  }

  /// Revokes the session credential in Cloud.
  Future<void> revokeSession(ProfileLabSession session) async {
    await _requestJson(
      'POST',
      _api(
          '/desktop-auth/sessions/${Uri.encodeComponent(session.sessionId)}/revoke'),
      bearer: session.credential,
      body: const <String, Object?>{},
    );
  }

  void close() => _http.close(force: true);
}
