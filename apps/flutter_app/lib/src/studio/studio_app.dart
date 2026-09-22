import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../platform/platform_services.dart';
import 'studio_models.dart';
import 'studio_data.dart';
import 'studio_stores.dart';

class StudioApp extends StatefulWidget {
  const StudioApp(
      {super.key, required this.services, required this.dataSource});

  final PlatformServices services;
  final StudioDataSource dataSource;

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  late StudioSnapshot snapshot;
  String? selectedWorkspaceId;
  String? selectedProjectId;
  RunStatus? optimisticRunStatus;
  Timer? refreshTimer;
  bool isLoading = true;
  String? loadError;
  String? selectedTaskId = 'implement';
  String? selectedChatId;
  int navigationIndex = 0;
  bool showRunDetails = false;
  final Set<String> expandedProjectIds = {'forge'};
  bool showNewGoal = false;
  bool showWorkerDrawer = false;
  String? workerActionMessage;
  StudioAgentEnrollment? enrollmentResult;
  StudioQualityPreset selectedQuality = StudioQualityPreset.balanced;
  final Map<String, bool> workerEnabled = {};
  final objectiveController = TextEditingController();
  final revisionController = TextEditingController();
  final chatController = TextEditingController();
  final List<StudioChatMessage> localChatMessages = [];
  late final StudioStore store;
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  void _showSnackBar(String message) {
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  StudioProject? get selectedProject => snapshot.projects
      .where((project) => project.id == selectedProjectId)
      .firstOrNull;

  List<StudioWorkspace> get workspaces => store.workspaces.items;

  StudioTask? get selectedTask =>
      snapshot.tasks.where((task) => task.id == selectedTaskId).firstOrNull;

  StudioChat? get selectedChat =>
      snapshot.allChats
          .where((chat) => chat.id == (selectedChatId ?? snapshot.activeChatId))
          .firstOrNull ??
      snapshot.activeChat;

  String? get activeWorkspaceId =>
      snapshot.workspaceId ??
      selectedWorkspaceId ??
      store.workspaces.activeWorkspaceId;

  @override
  void initState() {
    super.initState();
    store = StudioStore(widget.dataSource);
    snapshot = StudioSnapshot.empty();
    unawaited(_loadSession());
    unawaited(_loadWorkspaces());
    _loadSnapshot();
  }

  Future<void> _loadSession() async {
    try {
      await store.auth.load();
      if (mounted) setState(() {});
    } catch (_) {
      // Snapshot loading reports the primary API error in the main surface.
    }
  }

  Future<void> _logout() async {
    try {
      await store.auth.logout();
      if (!mounted) return;
      setState(() {
        snapshot = StudioSnapshot.empty();
        selectedWorkspaceId = null;
        selectedProjectId = null;
      });
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _loadWorkspaces() async {
    try {
      final loaded = await store.workspaces.list();
      if (!mounted) return;
      setState(() {
        selectedWorkspaceId ??= loaded.firstOrNull?.id;
      });
    } catch (_) {
      // Snapshot loading remains the primary path for anonymous development.
    }
  }

  Future<void> _loadSnapshot(
      {String? projectId, String? workspaceId, bool showSpinner = true}) async {
    if (showSpinner) {
      setState(() {
        isLoading = true;
        loadError = null;
      });
    }
    try {
      final loaded = await store.reload(
          projectId: projectId,
          workspaceId: workspaceId ?? selectedWorkspaceId);
      if (!mounted) return;
      setState(() {
        snapshot = loaded;
        selectedWorkspaceId = workspaceId ?? selectedWorkspaceId;
        optimisticRunStatus = null;
        selectedQuality = loaded.policy?.preset ?? selectedQuality;
        selectedProjectId = loaded.projects.any(
                (project) => project.id == (projectId ?? selectedProjectId))
            ? (projectId ?? selectedProjectId)
            : loaded.projects.firstOrNull?.id;
        selectedChatId = loaded.activeChatId ?? loaded.activeChat?.id;
        isLoading = false;
        if (loaded.run?.status == RunStatus.paused) {
          // The API is the source of truth; no local pause state is maintained.
        }
      });
      _scheduleRefresh(loaded);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        loadError = error.toString();
      });
    }
  }

  void _scheduleRefresh(StudioSnapshot loaded) {
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

  Future<void> _revokeAgent(String agentId) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      await store.agents.revoke(workspaceId, agentId);
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _announceAgentUpdate(StudioAgent agent) async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      await store.agents.announceUpdate(
        workspaceId,
        agent.id,
        channel: agent.updateChannel == '—' ? 'stable' : agent.updateChannel,
      );
      if (!mounted) return;
      _showSnackBar('Update announced to the Agent.');
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Future<void> _enrollAgent() async {
    final workspaceId = snapshot.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) return;
    try {
      final enrollment = await store.agents.createEnrollment(workspaceId);
      if (!mounted) return;
      setState(() {
        enrollmentResult = enrollment;
        loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  // Retained only while the legacy Studio data adapter is being retired. It
  // is no longer reachable from the v4 catalog UI.
  // ignore: unused_element
  Future<void> _editWorker([StudioWorker? existing]) async {
    if (snapshot.agents.isEmpty || snapshot.plugins.isEmpty) {
      if (mounted) {
        setState(() => workerActionMessage =
            'Connect an Agent and publish a Plugin before creating a Worker.');
        await showDialog<void>(
          context: navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Worker prerequisites missing'),
            content: const Text(
                'A Worker needs one connected Agent and one published Plugin. '
                'Open Agents or Plugins in the sidebar to finish setup, then '
                'return here.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final workspaceId = activeWorkspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      if (mounted) {
        setState(() => workerActionMessage =
            'Select a workspace before creating a Worker.');
        await showDialog<void>(
          context: navigatorKey.currentContext ?? context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Workspace required'),
            content: const Text(
                'Select a workspace from the sidebar, then try creating the '
                'Worker again.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
      return;
    }
    final nameController = TextEditingController(text: existing?.name ?? '');
    final rolesController = TextEditingController(
        text: (existing?.roles.isNotEmpty == true
                ? existing!.roles
                : const ['researcher'])
            .join(', '));
    final capabilitiesController = TextEditingController(
        text: (existing?.capabilities.isNotEmpty == true
                ? existing!.capabilities
                : const ['repository_read'])
            .join(', '));
    final configController = TextEditingController(
        text:
            const JsonEncoder.withIndent('  ').convert(existing?.config ?? {}));
    final versionPolicyController =
        TextEditingController(text: existing?.pluginVersionPolicy ?? 'latest');
    final independenceController =
        TextEditingController(text: existing?.independenceKey ?? '');
    final concurrencyController =
        TextEditingController(text: '${existing?.concurrencyLimit ?? 1}');
    final configuredAgentId = existing?.agentId;
    var agentId = configuredAgentId != null &&
            snapshot.agents.any((agent) => agent.id == configuredAgentId)
        ? configuredAgentId
        : snapshot.agents.firstOrNull?.id;
    final configuredPluginId = existing?.pluginId;
    var pluginId = configuredPluginId != null &&
            snapshot.plugins.any((plugin) => plugin.id == configuredPluginId)
        ? configuredPluginId
        : snapshot.plugins.firstOrNull?.id;
    var enabled = existing?.status.toLowerCase() != 'disabled';
    var sessionPolicy = existing?.sessionPolicy ?? 'stateless';
    var billingMode = existing?.billingMode ?? 'local_compute';
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: navigatorKey.currentContext ?? context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(existing == null ? 'Create Worker' : 'Edit Worker'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nameController,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: agentId,
                  decoration: const InputDecoration(labelText: 'Agent'),
                  items: snapshot.agents
                      .map((agent) => DropdownMenuItem(
                          value: agent.id, child: Text(agent.name)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => agentId = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: pluginId,
                  decoration: const InputDecoration(labelText: 'Plugin'),
                  items: snapshot.plugins
                      .map((plugin) => DropdownMenuItem(
                          value: plugin.id, child: Text(plugin.name)))
                      .toList(),
                  onChanged: (value) => setDialogState(() => pluginId = value),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: rolesController,
                    decoration: const InputDecoration(
                        labelText: 'Roles (comma separated)')),
                const SizedBox(height: 10),
                TextField(
                    controller: capabilitiesController,
                    decoration: const InputDecoration(
                        labelText: 'Capabilities (comma separated)')),
                const SizedBox(height: 10),
                TextField(
                    controller: versionPolicyController,
                    decoration: const InputDecoration(
                        labelText: 'Plugin version policy')),
                const SizedBox(height: 10),
                TextField(
                    controller: configController,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: 'Model/config (JSON)')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: sessionPolicy,
                  decoration:
                      const InputDecoration(labelText: 'Session policy'),
                  items: const [
                    DropdownMenuItem(
                        value: 'stateless', child: Text('Stateless')),
                    DropdownMenuItem(
                        value: 'isolated_workspace',
                        child: Text('Isolated workspace')),
                    DropdownMenuItem(
                        value: 'reuse_session', child: Text('Reuse session')),
                    DropdownMenuItem(
                        value: 'persistent_context',
                        child: Text('Persistent context')),
                  ],
                  onChanged: (value) => setDialogState(() {
                    if (value != null) sessionPolicy = value;
                  }),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: concurrencyController,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Concurrency limit')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: billingMode,
                  decoration: const InputDecoration(labelText: 'Billing mode'),
                  items: const [
                    DropdownMenuItem(
                        value: 'local_compute', child: Text('Local compute')),
                    DropdownMenuItem(
                        value: 'subscription', child: Text('Subscription')),
                    DropdownMenuItem(
                        value: 'api_metered', child: Text('API metered')),
                    DropdownMenuItem(
                        value: 'external', child: Text('External')),
                    DropdownMenuItem(value: 'manual', child: Text('Manual')),
                    DropdownMenuItem(value: 'free', child: Text('Free')),
                  ],
                  onChanged: (value) => setDialogState(() {
                    if (value != null) billingMode = value;
                  }),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: independenceController,
                    decoration: const InputDecoration(
                        labelText: 'Independence key (optional)')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enabled'),
                    value: enabled,
                    onChanged: (value) =>
                        setDialogState(() => enabled = value)),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: nameController.text.trim().isEmpty ||
                        agentId == null ||
                        pluginId == null
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not open Worker editor: $error');
      }
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
      return;
    }
    if (saved != true || agentId == null || pluginId == null) {
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
      return;
    }
    try {
      await store.workers.save(
        workspaceId: workspaceId,
        workerId: existing?.id,
        name: nameController.text.trim(),
        agentId: agentId!,
        pluginId: pluginId!,
        roles: rolesController.text
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        capabilities: capabilitiesController.text
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        enabled: enabled,
        pluginVersionPolicy: versionPolicyController.text.trim().isEmpty
            ? 'latest'
            : versionPolicyController.text.trim(),
        config: _parseWorkerConfig(configController.text),
        sessionPolicy: sessionPolicy,
        concurrencyLimit: _parseConcurrency(concurrencyController.text),
        billingMode: billingMode,
        independenceKey: independenceController.text.trim(),
      );
      await _loadSnapshot(projectId: selectedProjectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    } finally {
      nameController.dispose();
      rolesController.dispose();
      capabilitiesController.dispose();
      configController.dispose();
      versionPolicyController.dispose();
      independenceController.dispose();
      concurrencyController.dispose();
    }
  }

  Map<String, dynamic> _parseWorkerConfig(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    try {
      final parsed = jsonDecode(trimmed);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } catch (_) {
      // The API will not receive malformed config; the editor falls back to {}.
    }
    return <String, dynamic>{};
  }

  int _parseConcurrency(String value) {
    final parsed = int.tryParse(value.trim()) ?? 1;
    return parsed < 1 ? 1 : parsed;
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    objectiveController.dispose();
    revisionController.dispose();
    chatController.dispose();
    super.dispose();
  }

  Future<void> _createGoal() async {
    final projectId = selectedProjectId;
    final objective = objectiveController.text.trim();
    final commitSha = revisionController.text.trim();
    if (projectId == null || objective.isEmpty || commitSha.isEmpty) {
      if (mounted) {
        _showSnackBar('Enter an objective and expected commit SHA.');
      }
      return;
    }
    try {
      await store.dataSource.createGoal(
        projectId: projectId,
        objective: objective,
        revision: commitSha,
      );
      objectiveController.clear();
      if (!mounted) return;
      setState(() => showNewGoal = false);
      await _loadSnapshot(projectId: projectId);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conclave Studio',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: _theme(),
      home: LayoutBuilder(
        builder: (context, constraints) {
          if (isLoading) return _loadingScaffold();
          if (loadError != null) return _errorScaffold();
          if (snapshot.projects.isEmpty) return _emptyWorkspaceScaffold();
          final compact = constraints.maxWidth < 900;
          return Scaffold(
            backgroundColor: const Color(0xfff7f8fa),
            drawer: compact ? Drawer(child: _sidebar(compact: true)) : null,
            body: Row(
              children: [
                if (!compact) SizedBox(width: 248, child: _sidebar()),
                Expanded(child: _content(compact)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _loadingScaffold() =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));

  Widget _errorScaffold() => Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_rounded, size: 40),
        const SizedBox(height: 12),
        const Text('Studio could not load live data'),
        const SizedBox(height: 6),
        Text(loadError ?? '', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _loadSnapshot, child: const Text('Retry')),
      ])));

  Widget _emptyWorkspaceScaffold() => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.folder_open_outlined,
                  size: 48, color: Color(0xff6254d9)),
              const SizedBox(height: 14),
              const Text('No projects yet',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('Create a project before starting a Conclave goal.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                  onPressed: _loadSnapshot,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload')),
            ]),
          ),
        ),
      );

  ThemeData _theme() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff7f8fa),
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6254d9), brightness: Brightness.light),
        fontFamily: 'Arial',
        cardTheme: const CardThemeData(
            margin: EdgeInsets.zero, elevation: 0, color: Colors.white),
      );

  Widget _sidebar({bool compact = false}) {
    return Builder(
      builder: (sidebarContext) => Container(
        color: const Color(0xff171725),
        padding: const EdgeInsets.fromLTRB(18, 24, 14, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: const Color(0xff7768ee),
                      borderRadius: BorderRadius.circular(9)),
                  child: const Icon(Icons.hub_rounded,
                      color: Colors.white, size: 18)),
              const SizedBox(width: 10),
              const Text('conclave',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      letterSpacing: -.3)),
            ]),
            const SizedBox(height: 32),
            if (workspaces.length > 1) ...[
              _workspaceSelector(),
              const SizedBox(height: 20),
            ],
            _sidebarLabel('WORKSPACE'),
            _navItem(Icons.chat_bubble_outline, 'Chats', 0,
                compact: compact, navigationContext: sidebarContext),
            _navItem(Icons.computer_outlined, 'Agents', 1,
                compact: compact, navigationContext: sidebarContext),
            _navItem(Icons.extension_outlined, 'Plugins', 2,
                compact: compact, navigationContext: sidebarContext),
            _navItem(Icons.people_alt_outlined, 'Workers', 3,
                compact: compact, navigationContext: sidebarContext),
            _navItem(Icons.analytics_outlined, 'Usage', 4,
                compact: compact, navigationContext: sidebarContext),
            const SizedBox(height: 26),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sidebarLabel('PROJECTS'),
                    ...snapshot.projects
                        .map((project) => _projectItem(project)),
                    TextButton.icon(
                      onPressed: _createChat,
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('New chat'),
                      style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          foregroundColor: Colors.white54,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8)),
                    ),
                  ],
                ),
              ),
            ),
            if (compact)
              _navItem(Icons.close_rounded, 'Close menu', -1,
                  compact: compact, navigationContext: sidebarContext),
            _navItem(Icons.settings_outlined, 'Settings', 5,
                compact: compact, navigationContext: sidebarContext),
            const SizedBox(height: 6),
            Row(children: [
              CircleAvatar(
                  radius: 15,
                  backgroundColor: const Color(0xffd8d2ff),
                  child: Text(_viewerInitials,
                      style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xff4238a0),
                          fontWeight: FontWeight.bold))),
              const SizedBox(width: 9),
              Expanded(
                  child: Text(
                      store.auth.viewer?.displayName ??
                          snapshot.viewer?.displayName ??
                          'Not signed in',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12))),
              PopupMenuButton<String>(
                tooltip: 'Account menu',
                onSelected: (value) {
                  if (value == 'logout') unawaited(_logout());
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'logout', child: Text('Log out')),
                ],
                icon: const Icon(Icons.more_horiz,
                    color: Colors.white38, size: 18),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  String get _viewerInitials {
    final name =
        (store.auth.viewer?.displayName ?? snapshot.viewer?.displayName ?? '')
            .trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    final initials = parts.take(2).map((part) => part[0]).join();
    return initials.toUpperCase();
  }

  Widget _sidebarLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)));

  Widget _workspaceSelector() => DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value:
              workspaces.any((workspace) => workspace.id == selectedWorkspaceId)
                  ? selectedWorkspaceId
                  : workspaces.first.id,
          isExpanded: true,
          dropdownColor: const Color(0xff29283c),
          icon: const Icon(Icons.unfold_more, color: Colors.white54, size: 17),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: workspaces
              .map((workspace) => DropdownMenuItem<String>(
                    value: workspace.id,
                    child:
                        Text(workspace.name, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (workspaceId) {
            if (workspaceId == null || workspaceId == selectedWorkspaceId) {
              return;
            }
            setState(() {
              selectedWorkspaceId = workspaceId;
              selectedProjectId = null;
              selectedChatId = null;
            });
            _loadSnapshot(workspaceId: workspaceId);
          },
        ),
      );

  Widget _navItem(IconData icon, String label, int index,
      {String? badge, bool compact = false, BuildContext? navigationContext}) {
    final active = navigationIndex == index;
    return InkWell(
      onTap: () {
        if (index >= 0) {
          setState(() {
            navigationIndex = index;
            showRunDetails = index != 0;
          });
          Scaffold.maybeOf(navigationContext ?? context)?.closeDrawer();
        }
      },
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: active ? const Color(0xff302d4b) : Colors.transparent,
            borderRadius: BorderRadius.circular(9)),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: active ? const Color(0xffbcb3ff) : Colors.white54),
            const SizedBox(width: 11),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: active ? Colors.white : Colors.white60,
                        fontSize: 13,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400))),
            if (badge != null)
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0xff6254d9),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(badge,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)))
          ],
        ),
      ),
    );
  }

  Widget _projectItem(StudioProject project) {
    final active = selectedProject?.id == project.id;
    final expanded = expandedProjectIds.contains(project.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: () {
          setState(() {
            selectedProjectId = project.id;
            expandedProjectIds.add(project.id);
            selectedChatId = project.chats.firstOrNull?.id;
          });
          _loadSnapshot(projectId: project.id);
        },
        borderRadius: BorderRadius.circular(9),
        child: Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
              color: active ? const Color(0xff29283c) : Colors.transparent,
              borderRadius: BorderRadius.circular(9)),
          child: Row(children: [
            Icon(expanded ? Icons.expand_more : Icons.chevron_right,
                size: 15, color: Colors.white38),
            const SizedBox(width: 2),
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    color: active ? const Color(0xff70d6a5) : Colors.white30,
                    shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(project.name,
                    style: TextStyle(
                        color: active ? Colors.white : Colors.white60,
                        fontSize: 12))),
            if (project.activeGoals > 0)
              Text('${project.activeGoals}',
                  style:
                      const TextStyle(color: Color(0xffaaa4d9), fontSize: 11))
          ]),
        ),
      ),
      if (expanded)
        ...project.chats.map(
          (chat) => InkWell(
            onTap: () => setState(() {
              selectedProjectId = project.id;
              selectedChatId = chat.id;
              showRunDetails = false;
              navigationIndex = 0;
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 7, 8, 7),
              child: Row(children: [
                Icon(Icons.chat_bubble_outline,
                    size: 13,
                    color: selectedChatId == chat.id
                        ? const Color(0xffbcb3ff)
                        : Colors.white38),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: selectedChatId == chat.id
                                ? Colors.white
                                : Colors.white54,
                            fontSize: 11))),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _content(bool compact) {
    return Column(children: [
      _topbar(compact),
      Expanded(
          child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  compact ? 18 : 34, 26, compact ? 18 : 34, 40),
              child: showRunDetails
                  ? _runDetailsView(compact)
                  : _chatView(compact))),
    ]);
  }

  Widget _topbar(bool compact) {
    return Container(
      height: 66,
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 32),
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xffe8e8ed)))),
      child: Row(children: [
        if (showRunDetails)
          IconButton(
              onPressed: () => setState(() => showRunDetails = false),
              icon: const Icon(Icons.arrow_back_rounded)),
        if (compact)
          Builder(
              builder: (context) => IconButton(
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const Icon(Icons.menu_rounded))),
        Expanded(
            child: Text(showRunDetails ? 'Run details' : 'Studio',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff20202c)))),
        IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none_rounded,
                size: 21, color: Color(0xff6e6e7a))),
        const SizedBox(width: 5),
        OutlinedButton.icon(
            onPressed: () =>
                setState(() => showWorkerDrawer = !showWorkerDrawer),
            icon: const Icon(Icons.circle, size: 8, color: Color(0xff55bf8f)),
            label: Text(
                '${snapshot.workers.where((worker) => worker.status.toLowerCase() == 'available' || worker.status.toLowerCase() == 'online').length} workers online'),
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xff565665),
                side: const BorderSide(color: Color(0xffe2e2e8)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10))),
      ]),
    );
  }

  Widget _runDetailsView(bool compact) {
    if (navigationIndex == 1) return _agentsView();
    if (navigationIndex == 2) return _pluginsView();
    if (navigationIndex == 3) return _workersView();
    if (navigationIndex == 4) return _usageView();
    if (navigationIndex == 5) return _settingsView();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(selectedProject!.name,
              style: const TextStyle(color: Color(0xff777683), fontSize: 12)),
          const SizedBox(height: 7),
          const Text('Workspace overview',
              style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff20202c),
                  letterSpacing: -.5)),
          const SizedBox(height: 5),
          const Text(
              'Follow the work, inspect the evidence, and keep the run moving.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13))
        ])),
        FilledButton.icon(
            key: const Key('new-goal-button'),
            onPressed: () => setState(() => showNewGoal = true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New goal'),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff6254d9),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13))),
      ]),
      const SizedBox(height: 25),
      _runHeader(compact),
      const SizedBox(height: 16),
      _policyCard(),
      const SizedBox(height: 16),
      if (compact) ...[
        _executionCard(),
        const SizedBox(height: 16),
        _taskDetailsCard(),
        const SizedBox(height: 16),
        _candidateOutputsCard()
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _executionCard()),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: _taskDetailsCard())
        ]),
      if (!compact) ...[
        const SizedBox(height: 16),
        _candidateOutputsCard(),
      ],
      const SizedBox(height: 16),
      if (compact) ...[
        _timelineCard(),
        const SizedBox(height: 16),
        _evidenceCard()
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _timelineCard()),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: _evidenceCard())
        ]),
      if (showWorkerDrawer) ...[const SizedBox(height: 16), _workerStrip()],
      if (showNewGoal) _newGoalDialog(),
    ]);
  }

  Future<void> _sendChatMessage() async {
    final chat = selectedChat;
    final text = chatController.text.trim();
    if (chat == null || text.isEmpty) return;
    chatController.clear();
    setState(() {
      localChatMessages.add(StudioChatMessage(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        sender: StudioMessageSender.user,
        text: text,
        timestamp: 'Just now',
      ));
    });
    try {
      final response = await store.chats.send(chat.projectId, chat.id, text);
      if (!mounted) return;
      setState(() => localChatMessages.add(response));
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _createChat() async {
    final projectId = selectedProjectId;
    if (projectId == null) return;
    final titleController = TextEditingController();
    final title = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (context) => AlertDialog(
        title: const Text('New chat'),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'What would you like to work on?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, titleController.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    titleController.dispose();
    if (title == null || title.isEmpty) return;
    try {
      final chat = await store.chats.create(projectId, title);
      if (!mounted) return;
      setState(() {
        selectedChatId = chat.id;
        showRunDetails = false;
        navigationIndex = 0;
      });
      await _loadSnapshot(projectId: projectId, showSpinner: false);
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Widget _chatView(bool compact) {
    final chat = selectedChat;
    final messages = [
      ...?chat?.messages,
      ...localChatMessages,
    ];
    if (chat == null) {
      return _panel(
        title: 'Start a conversation',
        subtitle: 'Choose a project chat from the sidebar',
        child: FilledButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.add),
          label: const Text('New chat'),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(selectedProject?.name ?? 'Project',
                style: const TextStyle(color: Color(0xff777683), fontSize: 12)),
            const SizedBox(height: 6),
            Text(chat.title,
                style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff20202c))),
            const SizedBox(height: 5),
            const Text(
                'Chat with Conclave and follow multi-worker execution inline.',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          ]),
        ),
        OutlinedButton.icon(
          onPressed: _createChat,
          icon: const Icon(Icons.add, size: 17),
          label: const Text('New chat'),
        ),
      ]),
      const SizedBox(height: 22),
      _panel(
        title: 'Conversation',
        subtitle:
            '${messages.length} messages · ${_qualityLabel(selectedQuality)} policy',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...messages.map(_chatMessage),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: chatController,
                  minLines: 1,
                  maxLines: 5,
                  onSubmitted: (_) => _sendChatMessage(),
                  decoration: InputDecoration(
                    hintText: 'Ask Conclave to research, plan, or implement…',
                    filled: true,
                    fillColor: const Color(0xfff7f7fa),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                  onPressed: _sendChatMessage,
                  icon: const Icon(Icons.arrow_upward_rounded)),
            ]),
          ],
        ),
      ),
    ]);
  }

  Widget _chatMessage(StudioChatMessage message) {
    final isUser = message.sender == StudioMessageSender.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xff6254d9) : const Color(0xfffafaff),
          borderRadius: BorderRadius.circular(13),
          border: isUser ? null : Border.all(color: const Color(0xffe6e3f8)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message.text,
              style: TextStyle(
                  color: isUser ? Colors.white : const Color(0xff393743),
                  fontSize: 13,
                  height: 1.45)),
          const SizedBox(height: 5),
          Text(message.timestamp,
              style: TextStyle(
                  color: isUser ? Colors.white70 : const Color(0xffaaa8b1),
                  fontSize: 10)),
          if (message.runPreview != null) ...[
            const SizedBox(height: 14),
            _runPreviewCard(message.runPreview!),
          ],
        ]),
      ),
    );
  }

  Widget _runPreviewCard(StudioRunPreview preview) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0xffdfdcf7))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.hub_rounded, color: Color(0xff6254d9), size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(preview.statusSummary,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 12))),
            Text('${preview.workerCount} workers',
                style: const TextStyle(color: Color(0xff888691), fontSize: 10)),
          ]),
          const SizedBox(height: 12),
          ...preview.phases.map((phase) => _phaseIndicator(phase)),
          if (preview.finalAnswer != null) ...[
            const Divider(height: 20),
            const Text('Final synthesized answer',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(height: 6),
            Text(preview.finalAnswer!,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xff575564), fontSize: 12, height: 1.4)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => setState(() {
                showRunDetails = true;
                navigationIndex = 0;
              }),
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('Open run details'),
            ),
          ),
        ]),
      );

  Widget _phaseIndicator(StudioPhaseItem phase) {
    final (icon, color) = switch (phase.status) {
      StudioPhaseStatus.completed => (
          Icons.check_circle_rounded,
          const Color(0xff43b17f)
        ),
      StudioPhaseStatus.inProgress => (
          Icons.radio_button_checked,
          const Color(0xff6254d9)
        ),
      StudioPhaseStatus.pending => (
          Icons.radio_button_unchecked,
          const Color(0xffaaa8b1)
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(phase.name,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
        if (phase.detail != null) ...[
          const SizedBox(width: 8),
          Expanded(
              child: Text(phase.detail!,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Color(0xff96949e), fontSize: 10))),
        ],
      ]),
    );
  }

  Color _runStatusColor(RunStatus status) => switch (status) {
        RunStatus.completed => const Color(0xff43b17f),
        RunStatus.failed || RunStatus.cancelled => const Color(0xffbd6565),
        RunStatus.paused || RunStatus.waiting => const Color(0xffedb84d),
        _ => const Color(0xff6254d9),
      };

  String _statusLabel(RunStatus status) =>
      status.name[0].toUpperCase() + status.name.substring(1);

  Future<void> _controlRun(String command) async {
    final runId = snapshot.run?.id ?? snapshot.activeRunId;
    if (runId == null) return;
    try {
      await store.runs.control(runId, command);
      if (!mounted) return;
      setState(() {
        optimisticRunStatus = switch (command) {
          'pause' => RunStatus.paused,
          'resume' => RunStatus.running,
          'cancel' => RunStatus.cancelled,
          _ => optimisticRunStatus,
        };
      });
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Widget _runHeader(bool compact) {
    final run = snapshot.run;
    final status = optimisticRunStatus ?? run?.status ?? RunStatus.completed;
    final canControl = run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(status);
    final paused = status == RunStatus.paused;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
                spacing: 18,
                runSpacing: 15,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.bolt_rounded,
                      color: Color(0xff6254d9), size: 24),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(run?.objective ?? 'No goal has been started',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(
                            run == null
                                ? 'Select New goal to begin'
                                : 'Run ${run.id} · Forge',
                            style: const TextStyle(
                                color: Color(0xff898896), fontSize: 11))
                      ]),
                  _statusChip(_statusLabel(status), _runStatusColor(status)),
                  const SizedBox(width: 5),
                  if (!compact)
                    Text(
                        '${run?.verifiedCriterionCount ?? 0} / ${run?.criterionCount ?? 0} criteria verified',
                        style: const TextStyle(
                            color: Color(0xff777683), fontSize: 11)),
                  OutlinedButton.icon(
                      onPressed: canControl
                          ? () => _controlRun(paused ? 'resume' : 'pause')
                          : null,
                      icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16),
                      label: Text(paused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                  OutlinedButton.icon(
                      onPressed:
                          canControl ? () => _controlRun('cancel') : null,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xffa45555),
                          side: const BorderSide(color: Color(0xffefd5d5)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                ])));
  }

  Widget _executionCard() {
    final run = snapshot.run;
    if (snapshot.tasks.isEmpty) {
      return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(run == null
              ? 'No active run for this project.'
              : 'The run has not created tasks yet.'),
        ),
      );
    }
    final completed = snapshot.tasks
        .where((task) => task.status == TaskStatus.completed)
        .length;
    return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        trailing: _statusChip('$completed / ${snapshot.tasks.length} tasks',
            const Color(0xff6254d9)),
        child: Column(children: snapshot.tasks.map(_taskRow).toList()));
  }

  String _qualityLabel(StudioQualityPreset preset) => switch (preset) {
        StudioQualityPreset.highAssurance => 'High Assurance',
        StudioQualityPreset.exploration => 'Exploration',
        StudioQualityPreset.custom => 'Custom',
        StudioQualityPreset.economy => 'Economy',
        StudioQualityPreset.balanced => 'Balanced',
      };

  Widget _policyCard() {
    final policy = snapshot.policy;
    return _panel(
      title: 'Execution policy',
      subtitle: 'Configure worker routing for this run',
      trailing: _statusChip(
        policy?.mode ?? 'parallel',
        const Color(0xff6254d9),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...StudioQualityPreset.values.map(
            (preset) => ChoiceChip(
              label: Text(_qualityLabel(preset)),
              selected: selectedQuality == preset,
              onSelected: (_) => setState(() => selectedQuality = preset),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            policy == null
                ? 'No server policy attached'
                : '${policy.candidateCount} candidates · ${policy.maxParallel} parallel · ${policy.costCeiling}',
            style: const TextStyle(color: Color(0xff777683), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _candidateOutputsCard() {
    final outputs = snapshot.candidateOutputs;
    final decision = snapshot.synthesisDecision;
    if (outputs.isEmpty && decision == null) {
      return _panel(
        title: 'Candidate outputs',
        subtitle: 'Read-only ensemble and synthesis',
        child: const Text(
            'Candidate outputs will appear when a multi-worker policy runs.'),
      );
    }
    return _panel(
      title: 'Candidate outputs',
      subtitle: '${outputs.length} independent results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...outputs.map(
            (output) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffafaff),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xffe6e3f8)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 18, color: Color(0xff6254d9)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${output.worker} · ${output.role}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(output.summary,
                            style: const TextStyle(
                                color: Color(0xff777683), fontSize: 11)),
                      ],
                    ),
                  ),
                  _statusChip(output.status, const Color(0xff43b17f)),
                ],
              ),
            ),
          ),
          if (decision != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.auto_awesome,
                  color: Color(0xff6254d9), size: 18),
              const SizedBox(width: 8),
              const Text('Synthesis decision',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              _statusChip(decision.status, const Color(0xff43b17f)),
            ]),
            const SizedBox(height: 6),
            Text(decision.summary,
                style: const TextStyle(color: Color(0xff777683), fontSize: 11)),
            const SizedBox(height: 4),
            Text('${decision.worker} · ${decision.evidence}',
                style: const TextStyle(color: Color(0xff9a98a3), fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _taskRow(StudioTask task, {bool selected = false}) {
    final active = selectedTaskId == task.id;
    final color = task.status == TaskStatus.completed
        ? const Color(0xff43b17f)
        : task.status == TaskStatus.running
            ? const Color(0xff6254d9)
            : const Color(0xffaaa8b2);
    return InkWell(
        onTap: () => setState(() => selectedTaskId = task.id),
        borderRadius: BorderRadius.circular(9),
        child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: active ? const Color(0xfff3f1ff) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color:
                        active ? const Color(0xffdcd7ff) : Colors.transparent)),
            child: Row(children: [
              Icon(
                  task.status == TaskStatus.completed
                      ? Icons.check_circle_rounded
                      : task.status == TaskStatus.running
                          ? Icons.timelapse_rounded
                          : Icons.radio_button_unchecked,
                  size: 17,
                  color: color),
              const SizedBox(width: 9),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(task.title,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${task.worker}  ·  ${task.status.name}',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xff95939e)))
                  ])),
              if (task.status == TaskStatus.running)
                SizedBox(
                    width: 45,
                    child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(4),
                        color: const Color(0xff7467e4),
                        backgroundColor: const Color(0xffe3e0f7))),
              const SizedBox(width: 5),
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: Color(0xffb5b3bd))
            ])));
  }

  Widget _taskDetailsCard() {
    final task = selectedTask ?? snapshot.tasks.firstOrNull;
    if (task == null) {
      return _panel(
        title: 'Task details',
        subtitle: 'No task selected',
        child: const Text('Tasks will appear here when a run begins.'),
      );
    }
    return _panel(
        title: 'Task details',
        subtitle: task.id.toUpperCase(),
        trailing: _statusChip(
            task.status.name,
            task.status == TaskStatus.running
                ? const Color(0xff6254d9)
                : const Color(0xff43b17f)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(task.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          Text(task.detail,
              style: const TextStyle(
                  color: Color(0xff777683), fontSize: 12, height: 1.45)),
          const SizedBox(height: 18),
          _detailLine(Icons.person_outline, 'Worker', task.worker),
          _detailLine(
              Icons.account_tree_outlined,
              'Dependencies',
              task.dependencies.isEmpty
                  ? 'None'
                  : task.dependencies.join(', ')),
          _detailLine(Icons.token_outlined, 'Usage',
              '${task.tokens} tokens  ·  ${task.cost}'),
          const SizedBox(height: 15),
          if (task.status == TaskStatus.running)
            FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry task'),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffefedf9),
                    foregroundColor: const Color(0xff5549be),
                    elevation: 0))
        ]));
  }

  Widget _detailLine(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: const Color(0xff9997a3)),
        const SizedBox(width: 9),
        SizedBox(
            width: 82,
            child: Text(label,
                style:
                    const TextStyle(color: Color(0xff9997a3), fontSize: 11))),
        Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Color(0xff454450),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)))
      ]));

  Widget _timelineCard() => _panel(
        title: 'Run timeline',
        subtitle: 'Ordered events',
        trailing: TextButton(onPressed: () {}, child: const Text('View all')),
        child: Column(
          children: snapshot.events
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 42,
                          child: Text(event.time,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xffaaa8b1)))),
                      Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 3, right: 11),
                          decoration: const BoxDecoration(
                              color: Color(0xff786be4),
                              shape: BoxShape.circle)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                            const SizedBox(height: 3),
                            Text(event.detail,
                                style: const TextStyle(
                                    color: Color(0xff898792), fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );

  Widget _evidenceCard() => _panel(
      title: 'Evidence & findings',
      subtitle:
          '${snapshot.findings.length} findings · ${snapshot.artifacts.length} artifacts',
      trailing: TextButton(
          onPressed: () => setState(() => showRunDetails = true),
          child: const Text('Open run details')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _metric('Tokens', _formatNumber(snapshot.run?.tokens ?? 0)),
          _metric('Cost', _formatCost(snapshot.run?.costMicros ?? 0)),
          _metric('Checks',
              '${snapshot.run?.verifiedCriterionCount ?? 0} / ${snapshot.run?.criterionCount ?? 0}')
        ]),
        const SizedBox(height: 16),
        ...snapshot.findings.map((finding) => _findingRow(finding))
      ]));

  Widget _metric(String label, String value) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(color: Color(0xff9a98a3), fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xff393743)))
      ]));

  String _formatNumber(int value) => value == 0
      ? '0'
      : '${(value / 1000).toStringAsFixed(value >= 10000 ? 1 : 2)}k';

  String _formatCost(int micros) =>
      '\$${(micros / 1000000).toStringAsFixed(2)}';

  Widget _findingRow(StudioFinding finding) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: const Color(0xfffffaf4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xfff2e6d3))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            finding.status == FindingStatus.verified
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            size: 17,
            color: finding.status == FindingStatus.verified
                ? const Color(0xff42ae7e)
                : const Color(0xffd49a38)),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finding.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
          const SizedBox(height: 3),
          Text('${finding.severity.name} · ${finding.status.name}',
              style: const TextStyle(color: Color(0xff9b8a70), fontSize: 10))
        ]))
      ]));

  Widget _panel(
          {required String title,
          required String subtitle,
          required Widget child,
          Widget? trailing}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              color: Color(0xffaaa8b1), fontSize: 10)),
                    ],
                  ),
                  const Spacer(),
                  if (trailing != null) trailing,
                ],
              ),
              const SizedBox(height: 15),
              child,
            ],
          ),
        ),
      );

  Widget _statusChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700))
      ]));

  Widget _workerStrip() => _panel(
      title: 'Worker registry',
      subtitle: 'Capability-based routing',
      child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: snapshot.workers
              .map((worker) => Chip(
                  avatar: const Icon(Icons.circle,
                      size: 8, color: Color(0xff55bf8f)),
                  label: Text('${worker.name} · ${worker.provider}')))
              .toList()));

  Widget _fleetHeader(String title, String subtitle, IconData icon) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: const Color(0xffeeecff),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: const Color(0xff6254d9)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 25, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text(subtitle,
                  style:
                      const TextStyle(color: Color(0xff777683), fontSize: 13)),
            ]),
          ),
        ],
      );

  Widget _agentsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: _fleetHeader(
                  'Agents',
                  'Execution hosts connected to this workspace.',
                  Icons.computer_outlined),
            ),
            FilledButton.icon(
              onPressed: snapshot.workspaceId == null ? null : _enrollAgent,
              icon: const Icon(Icons.add_link),
              label: const Text('Enroll Agent'),
            ),
          ]),
          if (enrollmentResult != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Expanded(
                        child: Text('Agent enrollment token',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      IconButton(
                        tooltip: 'Hide token',
                        onPressed: () =>
                            setState(() => enrollmentResult = null),
                        icon: const Icon(Icons.close),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                        'Copy this one-time token into the Agent setup.'),
                    const SizedBox(height: 12),
                    SelectableText(enrollmentResult!.token,
                        style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(height: 8),
                    Text('Expires: ${enrollmentResult!.expiresAt}'),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (snapshot.agents.isEmpty)
            _emptyFleetCard('No agents enrolled',
                'Enroll a Conclave Agent to host local workers.')
          else
            ...snapshot.agents.map((agent) => Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text(agent.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 16))),
                            _statusChip(
                                agent.status,
                                agent.status.toLowerCase() == 'online'
                                    ? const Color(0xff3ca879)
                                    : const Color(0xff9a98a5)),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Announce update',
                              onPressed: agent.status.toLowerCase() == 'revoked'
                                  ? null
                                  : () => _announceAgentUpdate(agent),
                              icon: const Icon(Icons.system_update_outlined),
                            ),
                            IconButton(
                              tooltip: 'Revoke Agent',
                              onPressed: () => _revokeAgent(agent.id),
                              icon: const Icon(Icons.link_off_outlined),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          Text('${agent.hostname} · Agent ${agent.version}',
                              style: const TextStyle(color: Color(0xff777683))),
                          const SizedBox(height: 14),
                          Wrap(spacing: 20, runSpacing: 8, children: [
                            Text('${agent.os} · ${agent.architecture}'),
                            Text('Channel: ${agent.updateChannel}'),
                            Text('Last seen: ${agent.lastSeen}'),
                            Text('${agent.pluginCount} plugins'),
                            Text('${agent.workerCount} workers'),
                            Text('${agent.activeTaskCount} active task'),
                          ]),
                        ]),
                  ),
                )),
        ],
      );

  Widget _pluginsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fleetHeader(
              'Plugins',
              'Installed integrations and execution capabilities.',
              Icons.extension_outlined),
          const SizedBox(height: 24),
          if (snapshot.plugins.isEmpty)
            _emptyFleetCard('No plugins available',
                'Plugins will appear when an Agent reports its inventory.')
          else
            ...snapshot.plugins.map((plugin) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
                    leading: const CircleAvatar(
                        backgroundColor: Color(0xffeeecff),
                        child: Icon(Icons.extension_outlined,
                            color: Color(0xff6254d9))),
                    title: Text(plugin.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${plugin.version} · ${plugin.channel} · ${plugin.publisher}\n'
                        '${plugin.roles.join(', ')} · ${plugin.capabilities.join(' · ')}\n'
                        'Permissions: ${plugin.permissions.isEmpty ? 'none' : plugin.permissions.join(', ')}\n'
                        'Platforms: ${[
                      ...plugin.supportedOS,
                      ...plugin.supportedArchitecture
                    ].isEmpty ? 'any' : [
                            ...plugin.supportedOS,
                            ...plugin.supportedArchitecture
                          ].join(', ')} · ${plugin.installedAgentCount} Agents'),
                    isThreeLine: true,
                    trailing: _statusChip(
                        plugin.status,
                        plugin.status.toLowerCase() == 'installed'
                            ? const Color(0xff3ca879)
                            : const Color(0xff777683)),
                  ),
                )),
        ],
      );

  Widget _emptyFleetCard(String title, String subtitle) => _panel(
        title: title,
        subtitle: subtitle,
        child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Text('Nothing to configure yet.',
                style: TextStyle(color: Color(0xff777683)))),
      );

  Widget _workersView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fleetHeader(
              'Workers',
              'Configured resources resolved by role, capability, and Agent.',
              Icons.people_alt_outlined),
          const SizedBox(height: 24),
          if (workerActionMessage != null) ...[
            MaterialBanner(
              content: Text(workerActionMessage!),
              leading: const Icon(Icons.info_outline),
              actions: [
                TextButton(
                  onPressed: () => setState(() => workerActionMessage = null),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (snapshot.workers.isEmpty)
            _emptyFleetCard('No Worker catalog entries',
                'Workers are selected dynamically from catalog availability, accounts, and execution preferences.')
          else ...[
            const Text('Worker catalog',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
            const SizedBox(height: 24),
            _policyCard(),
            const SizedBox(height: 16),
            ...snapshot.workers.map(
              (worker) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xffeeecff),
                    child: Icon(
                        worker.role == 'reviewer'
                            ? Icons.rate_review_outlined
                            : Icons.smart_toy_outlined,
                        color: const Color(0xff6254d9),
                        size: 20),
                  ),
                  title: Text(worker.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${worker.agentName} · ${worker.pluginName}\n${worker.roles.isEmpty ? worker.role : worker.roles.join(', ')} · ${worker.capabilities.join(' · ')}'),
                  isThreeLine: true,
                  trailing: _statusChip(
                    worker.status,
                    worker.status.toLowerCase() == 'online'
                        ? const Color(0xff3ca879)
                        : const Color(0xff777683),
                  ),
                ),
              ),
            ),
          ],
        ],
      );

  Widget _usageView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Usage',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Token and cost accounting for the selected run.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          _panel(
            title: snapshot.run == null
                ? 'No run selected'
                : 'Run ${snapshot.run!.id}',
            subtitle: 'Usage is read from the Cloud run aggregate.',
            child: Row(children: [
              _metric('Tokens', _formatNumber(snapshot.run?.tokens ?? 0)),
              _metric('Cost', _formatCost(snapshot.run?.costMicros ?? 0)),
              _metric('Model calls', '${snapshot.modelCalls.length}'),
            ]),
          ),
        ],
      );

  Widget _settingsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Studio preferences and connection status.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          _panel(
              title: 'Connection',
              subtitle: 'Platform services',
              child: _detailLine(Icons.devices_other_outlined, 'Platform',
                  widget.services.platformName)),
          _panel(
            title: 'Verification defaults',
            subtitle: 'Applied to new Forge goals',
            child: const Column(
              children: [
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Standard verification'),
                    subtitle: Text('Independent review and blocking findings'),
                    trailing:
                        Icon(Icons.check_circle, color: Color(0xff43b17f))),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Pause before completion'),
                    subtitle: Text(
                        'Ask for approval when all automated evidence is present'),
                    trailing: Icon(Icons.toggle_off_outlined,
                        color: Color(0xff96949e))),
              ],
            ),
          ),
        ],
      );

  Widget _newGoalDialog() => Card(
        margin: const EdgeInsets.only(top: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 510),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create a goal',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Start a new run in the selected project.',
                    style: TextStyle(color: Color(0xff777683), fontSize: 12)),
                const SizedBox(height: 18),
                TextField(
                    controller: objectiveController,
                    decoration: const InputDecoration(
                        labelText: 'What should Conclave accomplish?',
                        hintText: 'Describe the outcome, not just the task',
                        border: OutlineInputBorder())),
                const SizedBox(height: 14),
                TextField(
                    controller: revisionController,
                    decoration: const InputDecoration(
                        labelText: 'Expected commit SHA',
                        hintText: 'The commit CI must verify',
                        border: OutlineInputBorder())),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => setState(() => showNewGoal = false),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: _createGoal,
                        child: const Text('Create goal')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
