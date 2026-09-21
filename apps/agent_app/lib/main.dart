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
  Future<bool> isOnline();

  factory AgentEngineConnection.unavailable() =
      UnavailableAgentEngineConnection;
}

class UnavailableAgentEngineConnection implements AgentEngineConnection {
  @override
  Future<bool> isOnline() async => false;
}

class AgentHome extends StatefulWidget {
  const AgentHome({required this.connection, super.key});

  final AgentEngineConnection connection;

  @override
  State<AgentHome> createState() => _AgentHomeState();
}

class _AgentHomeState extends State<AgentHome> {
  int _selectedIndex = 0;
  late Future<bool> _online;

  static const pages = <Widget>[
    _OverviewPage(),
    _WorkersPage(),
    _PluginsPage(),
    _LogsPage(),
    _SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _online = widget.connection.isOnline();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conclave AX Agent')),
      body: Row(
        children: [
          NavigationRail(
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
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_selectedIndex]),
        ],
      ),
      bottomNavigationBar: FutureBuilder<bool>(
        future: _online,
        builder: (context, snapshot) => ListTile(
          leading:
              Icon(snapshot.data == true ? Icons.cloud_done : Icons.cloud_off),
          title: Text(snapshot.data == true
              ? 'Agent Engine online'
              : 'Agent Engine offline'),
          subtitle: const Text(
              'The UI and execution engine run as separate processes.'),
        ),
      ),
    );
  }
}

class _OverviewPage extends StatelessWidget {
  const _OverviewPage();

  @override
  Widget build(BuildContext context) => const _Page(
        title: 'Agent overview',
        children: [
          _Metric(label: 'Workers', value: '0 configured'),
          _Metric(label: 'Plugins', value: '0 installed'),
          _Metric(label: 'Active tasks', value: '0'),
        ],
      );
}

class _WorkersPage extends StatelessWidget {
  const _WorkersPage();

  @override
  Widget build(BuildContext context) => const _Page(
      title: 'Workers',
      children: [Text('Workers registered with this Agent will appear here.')]);
}

class _PluginsPage extends StatelessWidget {
  const _PluginsPage();

  @override
  Widget build(BuildContext context) => const _Page(
      title: 'Plugins',
      children: [Text('Plugin installation and health will appear here.')]);
}

class _LogsPage extends StatelessWidget {
  const _LogsPage();

  @override
  Widget build(BuildContext context) => const _Page(
      title: 'Logs', children: [Text('Engine logs will appear here.')]);
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) =>
      const _Page(title: 'Settings', children: [
        Text('Connection, permissions, and update settings will appear here.')
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
