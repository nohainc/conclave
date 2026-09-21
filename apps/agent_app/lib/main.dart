import 'package:flutter/material.dart';

void main() {
  runApp(ConclaveAgentApp(connection: AgentEngineConnection.unavailable()));
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

class AgentSnapshot {
  const AgentSnapshot({
    required this.online,
    required this.status,
    required this.workers,
    required this.plugins,
    required this.activeTasks,
    this.version,
    this.updateAvailable,
    this.error,
  });

  final bool online;
  final String status;
  final int workers;
  final int plugins;
  final int activeTasks;
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
          _Metric(label: 'Workers', value: '${snapshot.workers} configured'),
          _Metric(label: 'Plugins', value: '${snapshot.plugins} installed'),
          _Metric(label: 'Active tasks', value: '${snapshot.activeTasks}'),
          if (snapshot.version != null)
            _Metric(label: 'Engine version', value: snapshot.version!),
          if (snapshot.updateAvailable != null)
            _Metric(
                label: 'Update available', value: snapshot.updateAvailable!),
        ],
      );
}

class _WorkersPage extends StatelessWidget {
  const _WorkersPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Workers', children: [
        const Text('Workers registered with this Agent will appear here.'),
        const SizedBox(height: 12),
        Text('Configured workers: ${snapshot.workers}'),
      ]);
}

class _PluginsPage extends StatelessWidget {
  const _PluginsPage({required this.snapshot});

  final AgentSnapshot snapshot;

  @override
  Widget build(BuildContext context) => _Page(title: 'Plugins', children: [
        const Text('Plugin installation and health will appear here.'),
        const SizedBox(height: 12),
        Text('Installed plugins: ${snapshot.plugins}'),
      ]);
}

class _LogsPage extends StatelessWidget {
  const _LogsPage();

  @override
  Widget build(BuildContext context) => const _Page(
      title: 'Logs', children: [Text('Engine logs will appear here.')]);
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
