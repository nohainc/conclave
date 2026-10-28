import 'package:flutter/material.dart';

import 'src/platform/platform_services.dart';
import 'src/app_shell.dart';
import 'src/ax/ax_data.dart';
import 'src/ax/ax_render_diagnostics.dart';

void main() {
  runSyntilaApp(() => runApp(const SyntilaApp()));
}

class SyntilaApp extends StatelessWidget {
  const SyntilaApp({
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
    return SyntilaAppShell(
      services: services,
      dataSource: dataSource ?? AxApiClient(),
      initialUri: initialUri,
    );
  }
}
