import 'package:flutter/material.dart';

import 'src/platform/platform_services.dart';
import 'src/studio/studio_app.dart';
import 'src/studio/studio_data.dart';

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
  final StudioDataSource? dataSource;
  final Uri? initialUri;

  @override
  Widget build(BuildContext context) {
    return StudioApp(
      services: services,
      dataSource: dataSource ?? StudioApiClient(),
      initialUri: initialUri,
    );
  }
}
