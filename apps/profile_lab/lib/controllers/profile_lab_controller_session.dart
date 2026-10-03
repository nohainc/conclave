part of 'profile_lab_controller.dart';

mixin _ProfileLabSessionOperations on _ProfileLabControllerState {
  @override
  Future<void> loadSavedSession() async {
    currentSession = await _sessionStore.load(cloudOrigin: cloudUrl);
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

    try {
      final intent = await client.createIntent();
      await client.openVerification(intent);

      final session = await client.waitForApprovalAndClaim(
        intent,
        isCancelled: () => _cancelSignInRequested,
      );

      await _sessionStore.save(session, cloudOrigin: cloudUrl);
      currentSession = session;
    } catch (e) {
      if (!_cancelSignInRequested) {
        authError = e.toString();
      }
    } finally {
      isSigningIn = false;
      _activeAuthClient = null;
      notifyListeners();
    }
  }

  /// Cancels in-progress browser-assisted sign-in.
  void cancelSignIn() {
    _cancelSignInRequested = true;
    _activeAuthClient?.close();
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
    currentSession = null;
    notifyListeners();
  }
}
