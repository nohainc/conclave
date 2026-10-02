import 'package:flutter/material.dart';

import 'src/platform/platform_services.dart';
import 'src/app_shell.dart';
import 'src/ax/ax_data.dart';

void main() {
  runApp(const ConclaveApp());
}

class ConclaveApp extends StatelessWidget {
  const ConclaveApp({
    super.key,
    this.services = const DefaultPlatformServices(),
    this.dataSource,
    this.initialUri,
  });

  final PlatformServices services;
  final AxDataSource? dataSource;
  final Uri? initialUri;

  @override
  Widget build(BuildContext context) {
    return ConclaveAppShell(
      services: services,
      dataSource: dataSource ?? AxApiClient(),
      initialUri: initialUri,
    );
  }
}
