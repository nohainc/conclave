import 'package:flutter/material.dart';

import 'src/platform/platform_services.dart';
import 'src/studio/studio_app.dart';

void main() {
  runApp(const ConclaveApp());
}

class ConclaveApp extends StatelessWidget {
  const ConclaveApp(
      {super.key, this.services = const DefaultPlatformServices()});

  final PlatformServices services;

  @override
  Widget build(BuildContext context) {
    return StudioApp(services: services);
  }
}
