import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'controllers/profile_lab_controller.dart';
import 'profile_lab_cloud_config.dart';
import 'profile_lab_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Startup diagnostics on stderr so a blank window can be diagnosed when the
  // app is launched from a terminal.
  FlutterError.onError = (details) {
    stderr.writeln('Profile Lab Flutter error: ${details.exceptionAsString()}');
    stderr.writeln(details.stack);
    FlutterError.presentError(details);
  };
  stderr.writeln(
    'Profile Lab starting (environment: '
    '${ProfileLabCloudConfig.environment}, cloud: '
    '${ProfileLabCloudConfig.buildDefaultOrigin})',
  );

  final paths = ProfileLabPaths();
  final controller = ProfileLabController(paths: paths);
  try {
    await controller.initialize();
    stderr.writeln('Profile Lab initialized; data: '
        '${paths.applicationSupportDirectory.path}');
  } catch (error, stack) {
    // Keep the management UI available when local startup state is stale or a
    // bundled diagnostic asset is unavailable. The UI can then show the error
    // and let the user repair the installation instead of rendering a blank
    // native window because runApp was never reached.
    stderr.writeln('Profile Lab startup failed: $error\n$stack');
    controller.startupError = error.toString();
    debugPrint('Profile Lab startup failed: $error\n$stack');
  }

  runApp(ProfileLabApp(controller: controller));
}
