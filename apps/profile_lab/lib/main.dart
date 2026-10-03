import 'package:flutter/material.dart';

import 'app.dart';
import 'controllers/profile_lab_controller.dart';
import 'profile_lab_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = ProfileLabPaths();
  final controller = ProfileLabController(paths: paths);
  await controller.initialize();

  runApp(ProfileLabApp(controller: controller));
}
