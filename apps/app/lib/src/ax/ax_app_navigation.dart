part of 'ax_app.dart';

extension _AxAppNavigationActions on _AxAppState {
  Future<void> _loadSnapshot(
      {String? projectId, String? workspaceId, bool showSpinner = true}) async {
    if (store.auth.session?.authenticated != true) return;
    if (showSpinner) {
      final reconnecting = !isLoading && snapshot.projects.isNotEmpty;
      setState(() {
        isLoading = true;
        loadError = null;
        isReconnecting = reconnecting;
      });
    }
    try {
      final loaded =
          await store.reload(projectId: projectId, workspaceId: workspaceId);
      if (!mounted) return;
      setState(() {
        snapshot = loaded;
        optimisticRunStatus = null;
        selectedProjectId = loaded.projects.any(
                (project) => project.id == (projectId ?? selectedProjectId))
            ? (projectId ?? selectedProjectId)
            : loaded.projects.firstOrNull?.id;
        isLoading = false;
        isReconnecting = false;
        authRequired = false;
        _applyNavigationToSnapshot(loaded);
        if (loaded.run?.status == RunStatus.paused) {
          // The API is the source of truth; no local pause state is maintained.
        }
      });
      _scheduleRefresh(loaded);
    } catch (error) {
      if (!mounted) return;
      if (error is AxApiException && error.statusCode == 401) {
        setState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      setState(() {
        isLoading = false;
        isReconnecting = false;
        loadError = error.toString();
      });
    }
  }

  Future<void> _syncSession() async {
    try {
      final session = await store.auth.load();
      if (!mounted) return;
      if (!session.authenticated && !authRequired) {
        setState(() => authRequired = true);
        browserNavigation.replaceWithLogin(navigation.toUri());
        return;
      }
      if (session.authenticated && authRequired) {
        final target = navigation.loginReturnTo == null
            ? const AxNavigation.home()
            : AxNavigation.fromUri(
                Uri.parse(navigation.loginReturnTo!),
              );
        setState(() {
          navigation = target;
          authRequired = false;
          isLoading = true;
          loadError = null;
        });
        browserNavigation.replace(target.toUri());
        await _loadWorkspaces();
        await _loadSnapshot();
      }
    } catch (_) {
      // The normal load/error path will explain an unavailable auth service.
    }
  }

  void _applyNavigationToSnapshot(AxSnapshot loaded) {
    final routeProject = navigation.projectId;
    if (routeProject != null &&
        loaded.projects.any((project) => project.id == routeProject)) {
      selectedProjectId = routeProject;
    }
    if (navigation.kind == AxRouteKind.workstream &&
        navigation.projectId != null) {
      expandedProjectIds.add(navigation.projectId!);
    }
  }

  void _onBrowserNavigation(Uri uri) {
    final next = AxNavigation.fromUri(uri);
    final canonicalUri = next.toUri();
    if (!_isCanonicalWorkspaceUri(uri, canonicalUri)) {
      browserNavigation.replace(canonicalUri);
    }
    if (next == navigation) return;
    final projectChanged =
        next.projectId != null && next.projectId != selectedProjectId;
    setState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      if (next.kind == AxRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (next.kind == AxRouteKind.profileSecurity) {
      unawaited(_loadAccountSecurity());
    }
    if (projectChanged) {
      unawaited(_loadSnapshot(projectId: next.projectId));
    }
    unawaited(realtimeClient.setScopes(
      projectId: next.projectId ?? selectedProjectId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  bool _isCanonicalWorkspaceUri(Uri actual, Uri canonical) =>
      actual.path == canonical.path &&
      mapEquals(actual.queryParameters, canonical.queryParameters);

  void _navigateTo(AxNavigation next, {bool replace = false}) {
    if (next.kind != AxRouteKind.search &&
        _searchQueryController.text.isNotEmpty) {
      _searchQueryController.removeListener(_onSearchQueryChanged);
      _searchQueryController.clear();
      _searchQuery = '';
      _navigationBeforeSearch = null;
      _searchQueryController.addListener(_onSearchQueryChanged);
    }
    setState(() {
      navigation = next;
      selectedProjectId = next.projectId ?? selectedProjectId;
      if (next.kind == AxRouteKind.workstream && next.projectId != null) {
        expandedProjectIds.add(next.projectId!);
      }
    });
    if (replace) {
      browserNavigation.replace(next.toUri());
    } else {
      browserNavigation.push(next.toUri());
    }
  }

  void _scheduleRefresh(AxSnapshot loaded) {
    refreshTimer?.cancel();
    if (loaded.run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(loaded.run!.status)) {
      refreshTimer = Timer(const Duration(seconds: 5), () {
        _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
      });
    }
  }
}
