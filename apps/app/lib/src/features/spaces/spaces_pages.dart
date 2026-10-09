import '../../ax/sync/ax_space_invitations.dart';
import '../invitations/space_invitation_dialog.dart';
import '../../ax/sync/ax_people.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../../ax/ax_data.dart';
import '../../ax/ax_models.dart';
import '../../ax/worker_presentation.dart';
import '../../ax/sync/ax_space_threads.dart';
import '../../ax/sync/ax_discussion_cache.dart';
import '../../ax/sync/ax_discussion_builder.dart';
import '../../ax/sync/ax_work_history.dart';
import '../../ax/sync/ax_work_realtime_sync.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/sync/ax_space_tab_queries.dart';
import '../../ax/sync/ax_sync_engine.dart';
import '../../ax/sync/persistence/ax_thread_view_state.dart';
import '../../ax/sync/persistence/ax_thread_view_state_store.dart';
import '../../ax/sync/ax_collaboration_mutations.dart';
import '../../brand.dart';
import '../workflows/workflows_page.dart';
import '../common/markdown_composer.dart';
import '../common/conclave_markdown_body.dart';
import '../../ax/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../ax/work_request_file_picker_web.dart'
    as work_request_files;

part 'spaces_pages/space_page.dart';
part 'spaces_pages/space_actions.dart';
part 'spaces_pages/space_tabs.dart';
part 'spaces_pages/thread_page.dart';
part 'spaces_pages/thread_actions.dart';
part 'spaces_pages/work_components.dart';

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
