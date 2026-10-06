import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../../ax/ax_data.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_project_workstreams.dart';
import '../../ax/sync/ax_discussion_cache.dart';
import '../../ax/sync/ax_discussion_builder.dart';
import '../../ax/sync/ax_work_history.dart';
import '../../ax/sync/ax_work_realtime_sync.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_project_workspace_grants.dart';
import '../../ax/sync/ax_project_tab_queries.dart';
import '../../ax/sync/ax_sync_engine.dart';
import '../../ax/sync/ax_collaboration_mutations.dart';
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

List<AxBuiltinWorkflow> _currentWorkflowVersions(
    List<AxBuiltinWorkflow> catalog) {
  final current = <String, AxBuiltinWorkflow>{};
  for (final workflow in catalog) {
    if (workflow.version > (current[workflow.id]?.version ?? 0)) {
      current[workflow.id] = workflow;
    }
  }
  return current.values.toList();
}

String _chatTimestamp(DateTime value) {
  final dt = value.toLocal();
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} · '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
