import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ax/ax_data.dart';
import '../../ax/ax_models.dart';
import '../../ax/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../ax/work_request_file_picker_web.dart'
    as work_request_files;

part 'projects_pages/project_page.dart';
part 'projects_pages/workstream_page.dart';
part 'projects_pages/work_components.dart';
part 'projects_pages/project_panel.dart';
