import 'package:flutter/material.dart';

import 'app.dart';
import 'controllers/profile_lab_controller.dart';
import 'profile_lab_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = ProfileLabPaths();
  final controller = ProfileLabController(paths: paths);
  try {
    await controller.initialize();
  } catch (error, stack) {
    // Keep the management UI available when local startup state is stale or a
    // bundled diagnostic asset is unavailable. The UI can then show the error
    // and let the user repair the installation instead of rendering a blank
    // native window because runApp was never reached.
    controller.startupError = error.toString();
    debugPrint('Profile Lab startup failed: $error\n$stack');
  }

  runApp(ProfileLabApp(controller: controller));
}
