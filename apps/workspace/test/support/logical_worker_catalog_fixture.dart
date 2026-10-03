import 'package:conclave_workspace/tool_profile_catalog.dart';

WorkerDescriptor logicalWorkerCatalogFixture(
  String workerTypeId, {
  String? displayName,
  String? profileDefinitionId,
  String? providerToolName,
}) =>
    WorkerDescriptor(
      workerTypeId: workerTypeId,
      displayName: displayName ??
          switch (workerTypeId) {
            'chatgpt' => 'ChatGPT',
            'gemini' => 'Gemini',
            _ => workerTypeId,
          },
      description: 'test Worker',
      profileDefinitionId: profileDefinitionId ??
          switch (workerTypeId) {
            'chatgpt' => 'chatgpt-codex',
            'gemini' => 'gemini-antigravity',
            _ => '$workerTypeId-profile',
          },
      providerToolName: providerToolName ??
          switch (workerTypeId) {
            'chatgpt' => 'codex',
            'gemini' => 'agy',
            _ => workerTypeId,
          },
      engineFamily: 'cli',
      visibilityState: 'visible',
      releaseStage: 'testing',
      capabilities: const ['text'],
      sortOrder: 1,
    );
