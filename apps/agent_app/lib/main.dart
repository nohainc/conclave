import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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

  Future<bool> isOnline() async => (await snapshot()).online;

  factory AgentEngineConnection.unavailable() =
      UnavailableAgentEngineConnection;
}

class UnavailableAgentEngineConnection implements AgentEngineConnection {
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
}

class SocketAgentEngineConnection implements AgentEngineConnection {
  const SocketAgentEngineConnection({required this.dataDirectory});

  final Directory dataDirectory;

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

  static int _integer(Object? value) => value is int ? value : 0;

  static List<String> _strings(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];
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

  @override
  void initState() {
    super.initState();
    _snapshot = widget.connection.snapshot();
  }

  void _refresh() => setState(() => _snapshot = widget.connection.snapshot());

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
        0 => _OverviewPage(snapshot: snapshot),
        1 => _WorkersPage(snapshot: snapshot),
        2 => _PluginsPage(snapshot: snapshot),
        3 => const _LogsPage(),
        _ => _SettingsPage(snapshot: snapshot),
      };
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(
        title: 'Agent overview',
        children: [
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
            _Metric(
                label: 'Update available', value: snapshot.updateAvailable!),
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

class _LogsPage extends StatelessWidget {
  const _LogsPage();

  @override
  Widget build(BuildContext context) => const _Page(title: 'Logs', children: [
        Text(
            'Logs are written by the Agent Engine and available in its local data directory.'),
        SizedBox(height: 12),
        Text(
            'Live log streaming will be enabled when the engine log channel is connected.'),
      ]);
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Settings', children: [
        const Text(
            'Connection, permissions, and update settings will appear here.'),
        const SizedBox(height: 12),
        Text('Connection status: ${snapshot.status}'),
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
