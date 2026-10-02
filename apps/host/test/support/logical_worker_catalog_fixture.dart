import 'package:conclave_host/tool_profile_catalog.dart';

LogicalWorkerCatalogEntry logicalWorkerCatalogFixture(String workerTypeId) =>
    LogicalWorkerCatalogEntry(
      workerTypeId: workerTypeId,
      displayName: switch (workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => workerTypeId,
      },
      description: 'test Worker',
      profileDefinitionId: switch (workerTypeId) {
        'chatgpt' => 'chatgpt-codex',
        'gemini' => 'gemini-antigravity',
        _ => '$workerTypeId-profile',
      },
      providerToolName: switch (workerTypeId) {
        'chatgpt' => 'codex',
        'gemini' => 'agy',
        _ => workerTypeId,
      },
      engineFamily: 'cli',
      releaseStage: 'testing',
      capabilities: const ['text'],
      sortOrder: 1,
    );
