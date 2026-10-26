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
  Map<String, Object?> _status = const {'phase': 'idle'};

  Map<String, Object?> status() => Map.of(_status);

  Future<Map<String, Object?>> start() async {
    if (_operation != null || _client != null) {
      throw const WorkspaceManagerProtocolException(
          'login_in_progress', 'Sign-in is already in progress.');
    }
    _cancelled = false;
    final client = _clientFactory(cloudUrl);
    _client = client;
    try {
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

  Future<void> _complete(
      DesktopAuthClient client, DesktopAuthIntent intent) async {
    try {
      final session = await client.waitForApprovalAndClaim(intent,
          isCancelled: () => _cancelled);
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
      final ownership = await client.checkWorkspaceOwnership(
          session: session,
          installationId: installationId,
          workspaceId: registration?.workspaceId,
          runtimeId: registration?.workspaceRuntimeId);
      final fresh = registration == null &&
          ownership.state == WorkspaceOwnershipState.unbound;
      final existing = registration != null &&
          ownership.state == WorkspaceOwnershipState.ownedByCurrentUser &&
          ownership.workspaceId == registration.workspaceId &&
          ownership.workspaceRuntimeId == registration.workspaceRuntimeId &&
          ownership.ownerUserId == session.userId &&
          registration.installationId == installationId;
      if (!fresh && !existing) throw StateError('Ownership requires recovery.');
      if (_cancelled) throw StateError('Cancelled.');
      _committing = true;
      if (fresh) {
        await WorkspaceRegistrationService(
                dataDirectory: dataDirectory, credentialStore: credentialStore)
            .registerWithDesktopSession(
                cloudUrl: cloudUrl,
                desktopCredential: session.credential,
                expectedOwnerUserId: session.userId,
                facts: SafeMachineFacts.collect(
                    installationId: installationId,
                    name: previous.customWorkspaceName ??
                        Platform.localHostname));
      } else if ((await credentialStore.read(registration!.workspaceRuntimeId))
              ?.isNotEmpty !=
          true) {
        throw StateError('Runtime credential needs explicit recovery.');
      }
      await credentialStore.write(
          desktopHumanCredentialKey, jsonEncode(session.toSecureJson()));
      await preferences.write(previous.copyWith(
          ownerUserId: session.userId, ownerDisplayName: session.displayName));
      await reloadRuntime();
      _status = const {'phase': 'complete'};
    } on Object {
      // Remote response text and credentials never enter public diagnostics.
      _status = {
        'phase': _cancelled ? 'cancelled' : 'failed',
        'message': _cancelled
            ? 'Sign-in cancelled.'
            : 'Sign-in or registration failed. Check Cloud access and existing ownership. Local state was retained; if registration completed, retry login.'
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
