/// Product branding only. Execution options come from Worker Profiles.
class WorkerPresentation {
  const WorkerPresentation({required this.name, this.iconAsset});

  final String name;
  final String? iconAsset;

  static WorkerPresentation resolve(
    String? workerTypeId,
    String? displayName, {
    String? profileDefinitionId,
    String? providerToolName,
  }) {
    final type = workerTypeId?.trim().toLowerCase() ?? '';
    final nameLower = displayName?.trim().toLowerCase() ?? '';
    final profileLower = profileDefinitionId?.trim().toLowerCase() ?? '';
    final toolLower = providerToolName?.trim().toLowerCase() ?? '';

    bool matches(List<String> tokens) {
      for (final token in tokens) {
        if (type == token || type.contains(token)) return true;
        if (nameLower.contains(token)) return true;
        if (profileLower.contains(token)) return true;
        if (toolLower.contains(token)) return true;
      }
      return false;
    }

    final WorkerPresentation brand;
    if (matches(const ['chatgpt', 'openai', 'codex'])) {
      brand = const WorkerPresentation(
          name: 'ChatGPT', iconAsset: 'assets/worker_icons/chatgpt.png');
    } else if (matches(const ['gemini', 'google', 'antigravity', 'agy'])) {
      brand = const WorkerPresentation(
          name: 'Gemini', iconAsset: 'assets/worker_icons/gemini.png');
    } else if (matches(const ['claude', 'anthropic'])) {
      brand = const WorkerPresentation(
          name: 'Claude', iconAsset: 'assets/worker_icons/claude.png');
    } else {
      brand = const WorkerPresentation(name: 'Worker');
    }

    return WorkerPresentation(
      name: displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : brand.name,
      iconAsset: brand.iconAsset,
    );
  }
}
