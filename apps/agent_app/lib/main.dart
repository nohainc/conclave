import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:conclave_agent_engine/agent_configuration.dart';
import 'package:conclave_agent_engine/secure_credentials.dart';
import 'package:conclave_agent_engine/local_ipc.dart';

void main() {
  runApp(ConclaveAgentApp(
    connection: SocketAgentEngineConnection(
      dataDirectory: Directory(
        '${Platform.environment['HOME'] ?? Directory.current.path}/.conclave-agent',
      ),
    ),
  ));
}

class ConclaveAgentApp extends StatelessWidget {
  const ConclaveAgentApp({required this.connection, super.key});

  final AgentEngineConnection connection;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conclave AX Agent',
      home: AgentHome(connection: connection),
    );
  }
}

abstract interface class AgentEngineConnection {
  Future<AgentSnapshot> snapshot();

  Future<List<String>> logs() async => const [];

  Future<bool> restart() async => false;

  Future<bool> update() async => false;

  Future<AgentRegistration?> registration() async => null;

  Future<AgentEnrollmentResult> enroll({
    required String cloudUrl,
    required String token,
    required String name,
  }) async {
    throw UnsupportedError('Agent enrollment is unavailable');
  }

  Future<bool> isOnline() async => (await snapshot()).online;

  factory AgentEngineConnection.unavailable() =
      UnavailableAgentEngineConnection;
}

class UnavailableAgentEngineConnection implements AgentEngineConnection {
  @override
  Future<AgentRegistration?> registration() async => null;

  @override
  Future<AgentEnrollmentResult> enroll({
    required String cloudUrl,
    required String token,
    required String name,
  }) async {
    throw UnsupportedError('Agent Engine is unavailable');
  }

  @override
  Future<bool> restart() async => false;

  @override
  Future<bool> update() async => false;

  @override
  Future<bool> isOnline() async => false;

  @override
  Future<AgentSnapshot> snapshot() async => const AgentSnapshot(
        online: false,
        status: 'offline',
        workers: 0,
        plugins: 0,
        activeTasks: 0,
      );

  @override
  Future<List<String>> logs() async => const [];
}

class SocketAgentEngineConnection implements AgentEngineConnection {
  const SocketAgentEngineConnection({required this.dataDirectory});

  final Directory dataDirectory;

  @override
  Future<AgentRegistration?> registration() async =>
      AgentRegistrationStore(dataDirectory).readSync();

  @override
  Future<AgentEnrollmentResult> enroll({
    required String cloudUrl,
    required String token,
    required String name,
  }) async {
    final base = Uri.parse(cloudUrl.trim());
    final endpoint = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/api/v2/agents/enroll',
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(endpoint);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'token': token.trim(),
        'name': name.trim().isEmpty ? 'Conclave Agent' : name.trim(),
        'hostname': Platform.localHostname,
      }));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map && decoded['error'] is String
            ? decoded['error'] as String
            : 'Enrollment failed with HTTP ${response.statusCode}';
        throw StateError(message);
      }
      if (decoded is! Map ||
          decoded['agentId'] is! String ||
          decoded['workspaceId'] is! String ||
          decoded['authToken'] is! String) {
        throw const FormatException(
            'Cloud returned an invalid enrollment response');
      }
      final result = AgentEnrollmentResult(
        agentId: decoded['agentId'] as String,
        workspaceId: decoded['workspaceId'] as String,
        authToken: decoded['authToken'] as String,
      );
      await const PlatformSecureCredentialStore()
          .write(result.agentId, result.authToken);
      await AgentRegistrationStore(dataDirectory).write(AgentRegistration(
        agentId: result.agentId,
        workspaceId: result.workspaceId,
        cloudUrl: base.toString(),
        name: name.trim().isEmpty ? 'Conclave Agent' : name.trim(),
        hostname: Platform.localHostname,
      ));
      return result;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<bool> isOnline() async => (await snapshot()).online;

  @override
  Future<AgentSnapshot> snapshot() async {
    final metadataFile = File('${dataDirectory.path}/ipc.json');
    if (!await metadataFile.exists()) {
      return const AgentSnapshot(
        online: false,
        status: 'offline',
        workers: 0,
        plugins: 0,
        activeTasks: 0,
      );
    }
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final port = metadata['port'];
      final token = metadata['token'];
      if (port is! int || token is! String || token.isEmpty) {
        throw const FormatException('invalid Agent Engine IPC metadata');
      }
      final client = await LocalIpcClient.connect(port: port, token: token);
      try {
        final result = await client.command('engine.status', const {});
        return AgentSnapshot(
          online: result['online'] == true,
          status: result['status'] is String
              ? result['status'] as String
              : 'unknown',
          workers: _integer(result['workers']),
          plugins: _integer(result['plugins']),
          activeTasks: _integer(result['activeTasks']),
          version: result['version'] as String?,
          cloudConnected: result['cloudConnected'] == true,
          pluginIds: _strings(result['pluginIds']),
          activeAssignmentIds: _strings(result['activeAssignmentIds']),
          healthWarnings: _strings(result['healthWarnings']),
          updatePhase: _updateField(result['update'], 'phase'),
          updateVersion: _updateField(result['update'], 'version'),
          updateError: _updateField(result['update'], 'error'),
        );
      } finally {
        await client.close();
      }
    } on Object catch (error) {
      return AgentSnapshot(
        online: false,
        status: 'error',
        workers: 0,
        plugins: 0,
        activeTasks: 0,
        error: 'Agent Engine unavailable: $error',
      );
    }
  }

  @override
  Future<List<String>> logs() async {
    final metadataFile = File('${dataDirectory.path}/ipc.json');
    if (!await metadataFile.exists()) return const [];
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final port = metadata['port'];
      final token = metadata['token'];
      if (port is! int || token is! String || token.isEmpty) return const [];
      final client = await LocalIpcClient.connect(port: port, token: token);
      try {
        final result =
            await client.command('engine.logs', const {'limit': 100});
        return result['lines'] is List
            ? (result['lines'] as List).whereType<String>().toList()
            : const [];
      } finally {
        await client.close();
      }
    } on Object {
      return const [];
    }
  }

  @override
  Future<bool> restart() async {
    final metadataFile = File('${dataDirectory.path}/ipc.json');
    if (!await metadataFile.exists()) return false;
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final port = metadata['port'];
      final token = metadata['token'];
      if (port is! int || token is! String || token.isEmpty) return false;
      final client = await LocalIpcClient.connect(port: port, token: token);
      try {
        final result = await client.command('engine.restart', const {});
        return result['accepted'] == true;
      } finally {
        await client.close();
      }
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> update() async {
    final metadataFile = File('${dataDirectory.path}/ipc.json');
    if (!await metadataFile.exists()) return false;
    try {
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
      final port = metadata['port'];
      final token = metadata['token'];
      if (port is! int || token is! String || token.isEmpty) return false;
      final client = await LocalIpcClient.connect(port: port, token: token);
      try {
        final result =
            await client.command('engine.update', const {'action': 'apply'});
        final phase = _updateField(result, 'phase');
        return phase == 'healthy' || phase == 'staged';
      } finally {
        await client.close();
      }
    } on Object {
      return false;
    }
  }

  static int _integer(Object? value) => value is int ? value : 0;

  static List<String> _strings(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

  static String? _updateField(Object? value, String field) =>
      value is Map && value[field] is String ? value[field] as String : null;
}

class AgentEnrollmentResult {
  const AgentEnrollmentResult({
    required this.agentId,
    required this.workspaceId,
    required this.authToken,
  });

  final String agentId;
  final String workspaceId;
  final String authToken;
}

class AgentSnapshot {
  const AgentSnapshot({
    required this.online,
    required this.status,
    required this.workers,
    required this.plugins,
    required this.activeTasks,
    this.cloudConnected = false,
    this.pluginIds = const [],
    this.activeAssignmentIds = const [],
    this.healthWarnings = const [],
    this.version,
    this.updateAvailable,
    this.updatePhase,
    this.updateVersion,
    this.updateError,
    this.error,
  });

  final bool online;
  final String status;
  final int workers;
  final int plugins;
  final int activeTasks;
  final bool cloudConnected;
  final List<String> pluginIds;
  final List<String> activeAssignmentIds;
  final List<String> healthWarnings;
  final String? version;
  final String? updateAvailable;
  final String? updatePhase;
  final String? updateVersion;
  final String? updateError;
  final String? error;
}

class AgentHome extends StatefulWidget {
  const AgentHome({required this.connection, super.key});

  final AgentEngineConnection connection;

  @override
  State<AgentHome> createState() => _AgentHomeState();
}

class _AgentHomeState extends State<AgentHome> {
  int _selectedIndex = 0;
  late Future<AgentSnapshot> _snapshot;
  late Future<AgentRegistration?> _registration;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.connection.snapshot();
    _registration = widget.connection.registration();
  }

  void _refresh() => setState(() => _snapshot = widget.connection.snapshot());

  Future<void> _enroll() async {
    final cloudController =
        TextEditingController(text: 'https://app.conclaveax.com');
    final tokenController = TextEditingController();
    final nameController = TextEditingController(text: 'Conclave Agent');
    final form = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enroll this Agent'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: cloudController,
                decoration: const InputDecoration(labelText: 'Cloud URL')),
            TextField(
                controller: tokenController,
                decoration:
                    const InputDecoration(labelText: 'Enrollment token'),
                maxLines: 2),
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Agent name')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, (
                    cloudController.text,
                    tokenController.text,
                    nameController.text
                  )),
              child: const Text('Enroll')),
        ],
      ),
    );
    cloudController.dispose();
    tokenController.dispose();
    nameController.dispose();
    if (form == null || !mounted) return;
    try {
      final result = await widget.connection.enroll(
        cloudUrl: form.$1,
        token: form.$2,
        name: form.$3,
      );
      final restarted = await widget.connection.restart();
      if (!mounted) return;
      setState(() {
        _registration = widget.connection.registration();
        _snapshot = widget.connection.snapshot();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(restarted
            ? 'Agent ${result.agentId} enrolled and restarting.'
            : 'Agent enrolled. Restart the Agent Engine to connect.'),
      ));
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Enrollment failed: $error')),
        );
      }
    }
  }

  Future<void> _restartEngine() async {
    final accepted = await widget.connection.restart();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(accepted
            ? 'Agent Engine restart requested.'
            : 'Agent Engine could not be restarted.'),
      ),
    );
    if (accepted) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _refresh();
    }
  }

  Future<void> _updateEngine() async {
    final accepted = await widget.connection.update();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(accepted
            ? 'Agent Engine update staged.'
            : 'Agent Engine update could not be applied.'),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conclave AX Agent'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))
        ],
      ),
      body: FutureBuilder<AgentSnapshot>(
        future: _snapshot,
        builder: (context, state) {
          if (state.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.hasError || !state.hasData) {
            return const Center(
                child: Text('Unable to read Agent Engine status.'));
          }
          final snapshot = state.data!;
          return Row(
            children: [
              _navigationRail(),
              const VerticalDivider(width: 1),
              Expanded(child: _pageFor(snapshot)),
            ],
          );
        },
      ),
      bottomNavigationBar: FutureBuilder<AgentSnapshot>(
        future: _snapshot,
        builder: (context, state) {
          final snapshot = state.data;
          final online = snapshot?.online == true;
          return ListTile(
            leading: Icon(online ? Icons.cloud_done : Icons.cloud_off),
            title:
                Text(online ? 'Agent Engine online' : 'Agent Engine offline'),
            subtitle: Text(snapshot?.error ??
                'The UI and execution engine run as separate processes.'),
          );
        },
      ),
    );
  }

  NavigationRail _navigationRail() => NavigationRail(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        labelType: NavigationRailLabelType.all,
        destinations: const [
          NavigationRailDestination(
              icon: Icon(Icons.home_outlined), label: Text('Overview')),
          NavigationRailDestination(
              icon: Icon(Icons.people_outline), label: Text('Workers')),
          NavigationRailDestination(
              icon: Icon(Icons.extension_outlined), label: Text('Plugins')),
          NavigationRailDestination(
              icon: Icon(Icons.article_outlined), label: Text('Logs')),
          NavigationRailDestination(
              icon: Icon(Icons.settings_outlined), label: Text('Settings')),
        ],
      );

  Widget _pageFor(AgentSnapshot snapshot) => switch (_selectedIndex) {
        0 => _OverviewPage(
            snapshot: snapshot,
            onUpdate: _updateEngine,
            onEnroll: _enroll,
            registration: _registration,
          ),
        1 => _WorkersPage(snapshot: snapshot),
        2 => _PluginsPage(snapshot: snapshot),
        3 => _LogsPage(connection: widget.connection),
        _ => _SettingsPage(snapshot: snapshot),
      };
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage(
      {required this.snapshot,
      required this.onUpdate,
      required this.onEnroll,
      required this.registration});

  final AgentSnapshot snapshot;
  final VoidCallback onUpdate;
  final VoidCallback onEnroll;
  final Future<AgentRegistration?> registration;

  @override
  Widget build(BuildContext context) => _Page(
        title: 'Agent overview',
        children: [
          FutureBuilder<AgentRegistration?>(
            future: registration,
            builder: (context, state) => Card(
              child: ListTile(
                leading: Icon(state.data == null ? Icons.link_off : Icons.link),
                title: Text(state.data == null
                    ? 'Agent not enrolled'
                    : 'Agent enrolled'),
                subtitle: Text(state.data == null
                    ? 'Paste an enrollment token from Studio to connect this machine.'
                    : '${state.data!.name} · ${state.data!.workspaceId}'),
                trailing: FilledButton(
                    onPressed: onEnroll,
                    child: Text(state.data == null ? 'Enroll' : 'Re-enroll')),
              ),
            ),
          ),
          if (!snapshot.online)
            const Card(
              child: ListTile(
                leading: Icon(Icons.warning_amber_outlined),
                title: Text('Agent Engine offline'),
                subtitle: Text(
                    'Start the Agent Engine to receive assignments on this machine.'),
              ),
            ),
          _Metric(label: 'Workers', value: '${snapshot.workers} configured'),
          _Metric(label: 'Plugins', value: '${snapshot.plugins} installed'),
          _Metric(label: 'Active tasks', value: '${snapshot.activeTasks}'),
          _Metric(
              label: 'Cloud',
              value: snapshot.cloudConnected ? 'Connected' : 'Disconnected'),
          if (snapshot.version != null)
            _Metric(label: 'Engine version', value: snapshot.version!),
          if (snapshot.updateAvailable != null)
            Card(
              child: ListTile(
                title: Text('Update available: ${snapshot.updateAvailable}'),
                subtitle: Text(snapshot.updateError ??
                    snapshot.updatePhase ??
                    'Ready to install'),
                trailing: FilledButton(
                  onPressed: snapshot.updatePhase == 'downloading' ||
                          snapshot.updatePhase == 'restarting'
                      ? null
                      : onUpdate,
                  child: const Text('Update'),
                ),
              ),
            ),
          if (snapshot.updatePhase != null &&
              snapshot.updatePhase != 'idle' &&
              snapshot.updateAvailable == null)
            _Metric(
              label: 'Update status',
              value: snapshot.updateError ??
                  '${snapshot.updatePhase}${snapshot.updateVersion == null ? '' : ' ${snapshot.updateVersion}'}',
            ),
          if (snapshot.healthWarnings.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.health_and_safety_outlined),
                title: const Text('Health warnings'),
                subtitle: Text(snapshot.healthWarnings.join('\n')),
              ),
            ),
        ],
      );
}

class _WorkersPage extends StatelessWidget {
  const _WorkersPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Workers', children: [
        if (!snapshot.online)
          const Text(
              'Workers are unavailable while the Agent Engine is offline.'),
        if (snapshot.online && snapshot.workers == 0)
          const Text('No Workers are configured on this Agent.'),
        if (snapshot.workers > 0)
          _Metric(label: 'Configured Workers', value: '${snapshot.workers}'),
        _Metric(
          label: 'Active assignments',
          value: '${snapshot.activeTasks}',
        ),
        if (snapshot.activeAssignmentIds.isNotEmpty)
          ...snapshot.activeAssignmentIds.map(
            (id) => Card(
              child: ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(id),
                subtitle: const Text('Assignment running'),
              ),
            ),
          ),
      ]);
}

class _PluginsPage extends StatelessWidget {
  const _PluginsPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Plugins', children: [
        if (!snapshot.online)
          const Text(
              'Plugin inventory is unavailable while the Agent Engine is offline.'),
        if (snapshot.online && snapshot.plugins == 0)
          const Text('No plugins are installed on this Agent.'),
        _Metric(label: 'Installed plugins', value: '${snapshot.plugins}'),
        ...snapshot.pluginIds.map(
          (id) => Card(
            child: ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text(id),
              subtitle: const Text('Installed on this Agent'),
            ),
          ),
        ),
      ]);
}

class _LogsPage extends StatefulWidget {
  const _LogsPage({required this.connection});

  final AgentEngineConnection connection;

  @override
  State<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<_LogsPage> {
  late Future<List<String>> _logs;

  @override
  void initState() {
    super.initState();
    _logs = widget.connection.logs();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
        future: _logs,
        builder: (context, state) {
          if (state.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final lines = state.data ?? const <String>[];
          return _Page(
            title: 'Logs',
            children: [
              Text('${lines.length} recent log entries'),
              const SizedBox(height: 12),
              if (lines.isEmpty)
                const Text('No Agent Engine logs are available.'),
              if (lines.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(lines.join('\n')),
                  ),
                ),
            ],
          );
        },
      );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Settings', children: [
        const Text('Connection and local host controls.'),
        const SizedBox(height: 12),
        Text('Connection status: ${snapshot.status}'),
        const SizedBox(height: 12),
        if (snapshot.online)
          FilledButton.icon(
            onPressed: () {
              final state = context.findAncestorStateOfType<_AgentHomeState>();
              state?._restartEngine();
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Restart Agent Engine'),
          ),
      ]);
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 24),
          ...children.map((child) => Padding(
              padding: const EdgeInsets.only(bottom: 16), child: child)),
        ],
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(title: Text(label), trailing: Text(value)),
      );
}
