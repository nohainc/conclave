import 'secure_credentials.dart';

enum CredentialOwnerType { user, workspace }

enum CredentialAuthType {
  none,
  apiKey,
  browserOAuth,
  cliLogin,
  interactiveCustom,
}

enum CredentialSecretLocation { none, hostSecureStore }

enum CredentialProfileStatus {
  setupRequired,
  authenticating,
  ready,
  expired,
  error,
  revoked,
}

enum CredentialSharingPolicy { privateOnly, ownerControlled, workspaceCapable }

class CredentialProfile {
  const CredentialProfile({
    required this.id,
    required this.workspaceId,
    required this.ownerType,
    required this.ownerId,
    required this.workerId,
    required this.hostId,
    required this.displayName,
    required this.authType,
    required this.status,
    required this.sharingPolicy,
    this.secretLocation = CredentialSecretLocation.hostSecureStore,
    this.providerMetadata = const {},
    this.concurrencyLimit,
  });

  final String id;
  final String workspaceId;
  final CredentialOwnerType ownerType;
  final String ownerId;
  final String workerId;
  final String? hostId;
  final String displayName;
  final CredentialAuthType authType;
  final CredentialSecretLocation secretLocation;
  final CredentialProfileStatus status;
  final CredentialSharingPolicy sharingPolicy;
  final Map<String, Object?> providerMetadata;
  final int? concurrencyLimit;

  CredentialProfile copyWith({
    CredentialProfileStatus? status,
    CredentialAuthType? authType,
    CredentialSecretLocation? secretLocation,
  }) =>
      CredentialProfile(
        id: id,
        workspaceId: workspaceId,
        ownerType: ownerType,
        ownerId: ownerId,
        workerId: workerId,
        hostId: hostId,
        displayName: displayName,
        authType: authType ?? this.authType,
        secretLocation: secretLocation ?? this.secretLocation,
        status: status ?? this.status,
        sharingPolicy: sharingPolicy,
        providerMetadata: providerMetadata,
        concurrencyLimit: concurrencyLimit,
      );

  /// The only representation safe to send to Cloud. It intentionally has no
  /// secret value or secret-bearing storage field.
  Map<String, Object?> toCloudMetadata() => {
        'credentialProfileId': id,
        'workspaceId': workspaceId,
        'ownerType': _ownerType(ownerType),
        'ownerId': ownerId,
        'workerId': workerId,
        if (hostId != null) 'hostId': hostId,
        'displayName': displayName,
        'authType': _authType(authType),
        'secretLocation': _secretLocation(secretLocation),
        if (secretLocation == CredentialSecretLocation.hostSecureStore)
          'secretReference': 'credential-profile/$hostId/$workerId/$id',
        'status': _status(status),
        'sharingPolicy': _sharingPolicy(sharingPolicy),
        'providerMetadata': providerMetadata,
        if (concurrencyLimit != null) 'concurrencyLimit': concurrencyLimit,
      };

  static String _ownerType(CredentialOwnerType value) => switch (value) {
        CredentialOwnerType.user => 'user',
        CredentialOwnerType.workspace => 'workspace',
      };

  static String _authType(CredentialAuthType value) => switch (value) {
        CredentialAuthType.none => 'none',
        CredentialAuthType.apiKey => 'api_key',
        CredentialAuthType.browserOAuth => 'oauth_browser',
        CredentialAuthType.cliLogin => 'local_cli_session',
        CredentialAuthType.interactiveCustom => 'interactive_custom',
      };

  static String _secretLocation(CredentialSecretLocation value) =>
      switch (value) {
        CredentialSecretLocation.none => 'none',
        CredentialSecretLocation.hostSecureStore => 'host_secure_store',
      };

  static String _status(CredentialProfileStatus value) => switch (value) {
        CredentialProfileStatus.setupRequired => 'setup_required',
        CredentialProfileStatus.authenticating => 'authenticating',
        CredentialProfileStatus.ready => 'ready',
        CredentialProfileStatus.expired => 'expired',
        CredentialProfileStatus.error => 'error',
        CredentialProfileStatus.revoked => 'revoked',
      };

  static String _sharingPolicy(CredentialSharingPolicy value) =>
      switch (value) {
        CredentialSharingPolicy.privateOnly => 'private_only',
        CredentialSharingPolicy.ownerControlled => 'owner_controlled',
        CredentialSharingPolicy.workspaceCapable => 'workspace_capable',
      };
}

class CredentialProfileStore {
  CredentialProfileStore({
    required this.hostId,
    SecureCredentialStore? store,
  }) : store = store ?? const PlatformSecureCredentialStore();

  final String hostId;
  final SecureCredentialStore store;

  String localKey(CredentialProfile profile) {
    _validate(profile);
    return 'credential-profile/$hostId/${profile.workerId}/${profile.id}';
  }

  Future<CredentialProfile> save(
    CredentialProfile profile,
    String secret, {
    CredentialAuthType? authType,
  }) async {
    _validate(profile);
    if (profile.secretLocation != CredentialSecretLocation.hostSecureStore) {
      throw StateError('credential profile is not local to this Host');
    }
    if (secret.isEmpty) throw ArgumentError('credential secret is required');
    await store.write(localKey(profile), secret);
    return profile.copyWith(
      authType: authType,
      status: CredentialProfileStatus.ready,
    );
  }

  Future<CredentialProfile> saveApiKey(
    CredentialProfile profile,
    String apiKey,
  ) =>
      save(profile, apiKey, authType: CredentialAuthType.apiKey);

  Future<CredentialProfile> completeBrowserOAuth(
    CredentialProfile profile,
    String sessionToken,
  ) =>
      save(profile, sessionToken, authType: CredentialAuthType.browserOAuth);

  Future<CredentialProfile> completeCliLogin(
    CredentialProfile profile,
    String sessionToken,
  ) =>
      save(profile, sessionToken, authType: CredentialAuthType.cliLogin);

  Future<String?> read(CredentialProfile profile) async {
    _validate(profile);
    if (profile.status == CredentialProfileStatus.revoked ||
        profile.secretLocation != CredentialSecretLocation.hostSecureStore) {
      return null;
    }
    return store.readSync(localKey(profile));
  }

  Future<CredentialProfile> clear(CredentialProfile profile) async {
    _validate(profile);
    await store.delete(localKey(profile));
    return profile.copyWith(status: CredentialProfileStatus.setupRequired);
  }

  Future<CredentialProfile> revoke(CredentialProfile profile) async {
    _validate(profile);
    await store.delete(localKey(profile));
    return profile.copyWith(status: CredentialProfileStatus.revoked);
  }

  CredentialProfile beginAuthentication(CredentialProfile profile) {
    _validate(profile);
    return profile.copyWith(status: CredentialProfileStatus.authenticating);
  }

  CredentialProfile markError(CredentialProfile profile) {
    _validate(profile);
    return profile.copyWith(status: CredentialProfileStatus.error);
  }

  void _validate(CredentialProfile profile) {
    if (hostId.isEmpty || profile.id.isEmpty || profile.workerId.isEmpty) {
      throw ArgumentError('host, profile, and worker identifiers are required');
    }
    if (profile.hostId != hostId) {
      throw StateError('credential profile belongs to a different Host');
    }
    for (final value in [hostId, profile.workerId, profile.id]) {
      if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
        throw ArgumentError('credential identifiers must be path-safe');
      }
    }
  }
}
