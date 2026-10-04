part of 'profile_lab_controller.dart';

mixin _ProfileLabSessionOperations on _ProfileLabControllerState {
  @override
  Future<void> loadSavedSession() async {
    currentSession = await _sessionStore.load(cloudOrigin: cloudUrl);
    if (currentSession != null) await refreshLabAccess();
    notifyListeners();
  }

  /// Binds a recent browser passkey ceremony to the active desktop session.
  Future<void> completeStepUpFromBrowser() async {
    final session = currentSession;
    if (session == null || session.isExpired) {
      throw StateError('Sign in to Profile Lab before completing step-up.');
    }
    final client = ProfileLabAuthClient(cloudUrl: cloudUrl);
    try {
      await client.completeStepUp(session);
    } finally {
      client.close();
    }
  }

  /// Starts the browser-assisted sign-in flow for the Profile Lab boundary.
  Future<void> signInWithBrowser({
    ProfileLabAuthClient? clientOverride,
  }) async {
    if (isSigningIn) return;
    isSigningIn = true;
    authError = null;
    _cancelSignInRequested = false;
    notifyListeners();

    final targetUrl = cloudUrl;
    final client = clientOverride ?? ProfileLabAuthClient(cloudUrl: targetUrl);
    _activeAuthClient = client;
    ProfileLabAuthIntent? claimedIntent;
    ProfileLabSession? claimedSession;
    var sessionSaved = false;

    try {
      final intent = await client.createIntent();
      claimedIntent = intent;
      _activeAuthIntent = intent;
      if (_cancelSignInRequested) {
        throw StateError('Profile Lab sign-in was cancelled.');
      }
      await client.openVerification(intent);

      final session = await client.waitForApprovalAndClaim(
        intent,
        isCancelled: () => _cancelSignInRequested,
      );
      claimedSession = session;
      if (_cancelSignInRequested) {
        throw StateError('Profile Lab sign-in was cancelled.');
      }
      await client.validateSession(session);

      await _sessionStore.save(session, cloudOrigin: cloudUrl);
      currentSession = session;
      sessionSaved = true;
      await refreshLabAccess();
      unawaited(ensureTabData(selectedTab));
    } catch (e) {
      if (!_cancelSignInRequested) {
        authError = e.toString();
      }
    } finally {
      if (!sessionSaved && claimedSession != null) {
        try {
          await client.revokeSession(claimedSession);
        } on Object {
          // The uncommitted credential remains short-lived if revocation fails.
        }
      } else if (claimedIntent != null && claimedSession == null) {
        try {
          await client.cancelIntent(claimedIntent);
        } on Object {
          // Approval or expiry may have won the race with local cleanup.
        }
      }
      _activeAuthIntent = null;
      client.close();
      isSigningIn = false;
      _activeAuthClient = null;
      notifyListeners();
    }
  }

  /// Cancels in-progress browser-assisted sign-in.
  Future<void> cancelSignIn() async {
    _cancelSignInRequested = true;
    final client = _activeAuthClient;
    final intent = _activeAuthIntent;
    if (client != null && intent == null) {
      // Let intent creation finish so its poll token can cancel it remotely.
      isSigningIn = false;
      notifyListeners();
      return;
    }
    if (client != null && intent != null) {
      try {
        await client.cancelIntent(intent);
      } on Object {
        // The browser may have just approved or the intent may have expired.
      }
    }
    client?.close();
    _activeAuthIntent = null;
    _activeAuthClient = null;
    isSigningIn = false;
    notifyListeners();
  }

  /// Sets the active session and notifies listeners (for testing).
  @visibleForTesting
  void setSessionForTesting(ProfileLabSession? session) {
    currentSession = session;
    notifyListeners();
  }

  /// Revokes the session on Cloud and clears local credential storage.
  Future<void> signOut() async {
    if (currentSession != null) {
      try {
        final client = ProfileLabAuthClient(cloudUrl: cloudUrl);
        await client.revokeSession(currentSession!);
        client.close();
      } catch (_) {}
    }
    await _sessionStore.clear();
    await _clearCloudOriginState();
    notifyListeners();
  }
}
