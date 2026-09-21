import 'package:flutter/material.dart';

void main() {
  runApp(const ConclaveAgentApp());
}

class ConclaveAgentApp extends StatelessWidget {
  const ConclaveAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conclave AX Agent',
      home: Scaffold(
        appBar: AppBar(title: const Text('Conclave AX Agent')),
        body: const Center(
          child: Text('Agent Engine migration in progress'),
        ),
      ),
    );
  }
}
