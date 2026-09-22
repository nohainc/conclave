import 'dart:async';
import 'package:flutter/material.dart';

import 'host.dart';

class HostLifecycleController extends ChangeNotifier {
  HostLifecycleController(this.host);

  final Host host;
  bool _hidden = false;
  bool _quitting = false;
  Object? _startupError;

  bool get hidden => _hidden;
  bool get quitting => _quitting;
  bool get running => host.isRunning;
  Object? get startupError => _startupError;

  Future<void> launch() async {
    try {
      await host.start();
    } catch (error) {
      _startupError = error;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  void minimize() {
    if (_quitting) return;
    _hidden = true;
    notifyListeners();
  }

  void restore() {
    if (_quitting) return;
    _hidden = false;
    notifyListeners();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    notifyListeners();
    await host.stop();
    notifyListeners();
  }
}

void main() {
  final host = Host(config: HostConfig.fromArgs(const []));
  runApp(ConclaveHostApp(lifecycle: HostLifecycleController(host)));
}

class ConclaveHostApp extends StatefulWidget {
  const ConclaveHostApp({required this.lifecycle, super.key});

  final HostLifecycleController lifecycle;

  @override
  State<ConclaveHostApp> createState() => _ConclaveHostAppState();
}

class _ConclaveHostAppState extends State<ConclaveHostApp> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.addListener(_refresh);
    unawaited(widget.lifecycle.launch());
  }

  @override
  void dispose() {
    widget.lifecycle.removeListener(_refresh);
    unawaited(widget.lifecycle.quit());
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final lifecycle = widget.lifecycle;
    return MaterialApp(
      title: 'Conclave Host',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Conclave Host'),
          actions: [
            IconButton(
              tooltip: lifecycle.hidden ? 'Restore' : 'Minimize',
              onPressed:
                  lifecycle.hidden ? lifecycle.restore : lifecycle.minimize,
              icon: Icon(
                lifecycle.hidden ? Icons.open_in_full : Icons.remove,
              ),
            ),
            IconButton(
              tooltip: 'Quit Host',
              onPressed: lifecycle.quit,
              icon: const Icon(Icons.power_settings_new),
            ),
          ],
        ),
        body: Center(
          child: lifecycle.hidden
              ? const Text('Host is running in the background.')
              : _HostStatus(lifecycle: lifecycle),
        ),
      ),
    );
  }
}

class _HostStatus extends StatelessWidget {
  const _HostStatus({required this.lifecycle});

  final HostLifecycleController lifecycle;

  @override
  Widget build(BuildContext context) {
    final status = lifecycle.quitting
        ? 'Stopping'
        : lifecycle.running
            ? 'Running'
            : 'Starting';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            const Text(
              'Cloud connection, assignment journal, Workers, credentials, process supervision, and logs are owned by this Host.',
            ),
            if (lifecycle.startupError != null) ...[
              const SizedBox(height: 12),
              Text(
                'Startup error: ${lifecycle.startupError}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
