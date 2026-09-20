import 'package:flutter/material.dart';

import 'src/platform/platform_services.dart';

void main() {
  runApp(const ConclaveApp());
}

class ConclaveApp extends StatelessWidget {
  const ConclaveApp({super.key, this.services = const DefaultPlatformServices()});

  final PlatformServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conclave',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('Conclave')),
        body: Center(child: Text('Platform: ${services.platformName}')),
      ),
    );
  }
}
