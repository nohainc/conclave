import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_auth.dart';
import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_manager_ipc.dart';
import 'workspace_registration.dart';

/// Service-owned approval: only public progress crosses IPC. Credentials stay
/// in the service and the installation's recorded credential store.
class WorkspaceHeadlessAuth {
  WorkspaceHeadlessAuth({
    required this.dataDirectory,
    required this.cloudUrl,
    required this.credentialStore,
    required this.reloadRuntime,
    DesktopAuthClient Function(String)? clientFactory,
  }) : _clientFactory =
            clientFactory ?? ((url) => DesktopAuthClient(cloudUrl: url));

  final Directory dataDirectory;
  final String cloudUrl;
  final SecureCredentialStore credentialStore;
  final Future<void> Function() reloadRuntime;
  final DesktopAuthClient Function(String) _clientFactory;
  DesktopAuthClient? _client;
  DesktopAuthIntent? _intent;
  Future<void>? _operation;
  bool _cancelled = false;
  bool _committing = false;
  bool _starting = false;
  Map<String, Object?> _status = const {'phase': 'idle'};

  Map<String, Object?> status() => Map.of(_status);

  Future<Map<String, Object?>> start({String? email, String? password}) async {
    if (_starting || _operation != null || _client != null) {
      throw const WorkspaceManagerProtocolException(
          'login_in_progress', 'Sign-in is already in progress.');
    }
    _cancelled = false;
    _starting = true;
    // Test a private temporary credential before creating any remote state.
    // A broken keyring must not leave a Cloud-only Workspace behind.
    final probeKey = 'setup-storage-probe-$pid';
    try {
      if (credentialStore is CredentialStorePreflight) {
        await (credentialStore as CredentialStorePreflight).verifyWritable();
      } else {
        await credentialStore.write(probeKey, 'storage-preflight');
        if (await credentialStore.read(probeKey) != 'storage-preflight') {
          throw StateError('Credential storage readback failed');
        }
        await credentialStore.delete(probeKey);
      }
    } on Object {
      _starting = false;
      throw const WorkspaceManagerProtocolException(
          'credential_store_unavailable',
          'Credential storage is unavailable. Check the recorded Linux credential store before signing in. No Cloud registration was started.');
    }
    final client = _clientFactory(cloudUrl);
    _client = client;
    _starting = false;
    try {
      if (email != null || password != null) {
        if (email == null ||
            email.trim().isEmpty ||
            password == null ||
            password.isEmpty) {
          throw const FormatException('Email and password are required');
        }
        _status = const {'phase': 'pending', 'stage': 'password_sign_in'};
        _operation = _complete(client, null, email: email, password: password);
        return status();
      }
      final intent = await client.createIntent();
      _intent = intent;
      _status = {
        'phase': 'pending',
        'verificationUrl': intent.verificationUrl.toString(),
        'expiresAt': intent.expiresAt.toUtc().toIso8601String()
      };
      _operation = _complete(client, intent);
      return status();
    } on Object {
      _client = null;
      client.close();
      throw const WorkspaceManagerProtocolException('login_unavailable',
          'Could not start sign-in. Check Cloud connectivity.');
    }
  }

  Future<void> _complete(DesktopAuthClient client, DesktopAuthIntent? intent,
      {String? email, String? password}) async {
    var stage = email == null ? 'approval' : 'password_sign_in';
    try {
      final session = email == null
          ? await client.waitForApprovalAndClaim(intent!,
              isCancelled: () => _cancelled)
          : await client.signInWithPassword(email, password!);
      stage = 'session_validation';
      await client.validateSession(session);
      final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
      final installationId =
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      final preferences = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final previous = preferences.readSync();
      if ((previous.ownerUserId != null &&
              previous.ownerUserId != session.userId) ||
          (registration != null &&
              registration.ownerUserId != session.userId)) {
        throw StateError('Existing owner differs.');
      }
      stage = 'ownership';
      final ownership = await client.checkWorkspaceOwnership(
          session: session,
          installationId: installationId,
          workspaceId: registration?.workspaceId,
          runtimeId: registration?.workspaceRuntimeId);
      final fresh = registration == null &&
          ownership.state == WorkspaceOwnershipState.unbound;
      final recoverCloudOnlyRegistration = registration == null &&
          ownership.state == WorkspaceOwnershipState.ownedByCurrentUser &&
          ownership.ownerMatchesCurrentSession == true &&
          ownership.ownerUserId == session.userId &&
          ownership.workspaceId != null;
      final existing = registration != null &&
          ownership.state == WorkspaceOwnershipState.ownedByCurrentUser &&
          ownership.workspaceId == registration.workspaceId &&
          ownership.workspaceRuntimeId == registration.workspaceRuntimeId &&
          ownership.ownerUserId == session.userId &&
          registration.installationId == installationId;
      if (!fresh && !recoverCloudOnlyRegistration && !existing) {
        throw StateError('Ownership requires recovery.');
      }
      if (_cancelled) throw StateError('Cancelled.');
      _committing = true;
      stage = 'registration';
      if (fresh || recoverCloudOnlyRegistration) {
        await WorkspaceRegistrationService(
                dataDirectory: dataDirectory, credentialStore: credentialStore)
            .registerWithDesktopSession(
                cloudUrl: cloudUrl,
                desktopCredential: session.credential,
                expectedOwnerUserId: session.userId,
                expectedWorkspaceId:
                    recoverCloudOnlyRegistration ? ownership.workspaceId : null,
                facts: SafeMachineFacts.collect(
                    installationId: installationId,
                    name: ownership.workspaceName ??
                        previous.customWorkspaceName ??
                        Platform.localHostname));
      } else if ((await credentialStore.read(registration!.workspaceRuntimeId))
              ?.isNotEmpty !=
          true) {
        await WorkspaceRegistrationService(
                dataDirectory: dataDirectory, credentialStore: credentialStore)
            .registerWithDesktopSession(
                cloudUrl: cloudUrl,
                desktopCredential: session.credential,
                expectedOwnerUserId: session.userId,
                expectedWorkspaceId: registration.workspaceId,
                facts: SafeMachineFacts.collect(
                    installationId: installationId,
                    name: registration.name,
                    hostname: registration.hostname));
      }
      stage = 'session_storage';
      await credentialStore.write(
          desktopHumanCredentialKey, jsonEncode(session.toSecureJson()));
      await preferences.write(previous.copyWith(
          ownerUserId: session.userId, ownerDisplayName: session.displayName));
      stage = 'runtime_reload';
      await reloadRuntime();
      _status = const {'phase': 'complete'};
    } on Object catch (error) {
      // Only enumerated, locally-authored password errors cross IPC. Remote
      // response text and credentials never enter public diagnostics.
      final passwordFailure =
          error is DesktopPasswordSignInException ? error : null;
      _status = {
        'phase': _cancelled ? 'cancelled' : 'failed',
        'stage': stage,
        'code': _cancelled
            ? 'login_cancelled'
            : passwordFailure?.code ?? 'login_${stage}_failed',
        'message': _cancelled
            ? 'Sign-in cancelled.'
            : passwordFailure?.message ??
                'Sign-in or registration failed. Check Cloud access and existing ownership. Local state was retained; if registration completed, retry login.'
      };
    } finally {
      _committing = false;
      _intent = null;
      _client = null;
      _operation = null;
      client.close();
    }
  }

  Future<Map<String, Object?>> cancel() async {
    if (_committing) {
      throw const WorkspaceManagerProtocolException(
          'login_committing', 'Registration is completing; wait for status.');
    }
    _cancelled = true;
    final client = _client;
    final intent = _intent;
    if (client != null && intent != null) {
      try {
        await client.cancelIntent(intent);
      } on Object {/* local cancellation still applies */}
    }
    return status();
  }

  Future<void> close() async {
    if (!_committing) {
      _cancelled = true;
      _client?.close();
    }
    await _operation;
  }
}
