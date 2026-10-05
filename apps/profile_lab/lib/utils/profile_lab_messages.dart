import '../controllers/profile_lab_controller.dart';
import 'profile_lab_security.dart';

String profileLabMessageReport(ProfileLabController c) {
  final messages = <String>[
    'Profile Lab · ${DateTime.now().toIso8601String()}',
    'Cloud: ${c.cloudUrl}',
    if (c.selectedDefinitionId != null) 'Profile: ${c.selectedDefinitionId}',
    for (final entry in <String, String?>{
      'Authentication': c.authError,
      'Cloud': c.cloudError,
      'Access': c.labAccessError,
      'Workers': c.workerCatalogError,
      'Definitions': c.definitionsError,
      'Releases': c.releasesError,
      'Evidence': c.evidenceError,
      'Activity': c.auditError,
      'Workspaces': c.workspaceError,
      'JSON validation': c.jsonValidationError,
      'AI proposal': c.aiProposalError,
      'Test status': c.testStatusMessage,
    }.entries)
      if (entry.value != null && entry.value!.isNotEmpty)
        '${entry.key}: ${entry.value}',
    if (c.testResultMatchesDraft)
      for (final log in c.testLogs)
        '${log.timestamp.toIso8601String()} ${log.level.toUpperCase()} · ${log.message}',
  ];
  return ProfileLabSecurity.redactSecrets(messages.join('\n'));
}
