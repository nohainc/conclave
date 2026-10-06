import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../../ax/ax_data.dart';
import '../../ax/ax_models.dart';
import '../../brand.dart';
import '../common/markdown_composer.dart';
import '../common/conclave_markdown_body.dart';
import '../../ax/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../ax/work_request_file_picker_web.dart'
    as work_request_files;

part 'projects_pages/project_page.dart';
part 'projects_pages/project_actions.dart';
part 'projects_pages/project_tabs.dart';
part 'projects_pages/workstream_page.dart';
part 'projects_pages/workstream_config.dart';
part 'projects_pages/workstream_actions.dart';
part 'projects_pages/work_components.dart';

String _chatTimestamp(DateTime value) {
  final dt = value.toLocal();
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} · '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
