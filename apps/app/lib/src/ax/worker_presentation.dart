/// Product branding only. Execution options come from Worker Profiles.
class WorkerPresentation {
  const WorkerPresentation({required this.name, this.iconAsset});

  final String name;
  final String? iconAsset;

  static WorkerPresentation resolve(String? workerTypeId, String? displayName) {
    final type = workerTypeId?.trim().toLowerCase() ?? '';
    final nameLower = displayName?.trim().toLowerCase() ?? '';

    final WorkerPresentation brand;
    if (type == 'chatgpt' ||
        type == 'openai' ||
        type.contains('chatgpt') ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('chatgpt') || nameLower.contains('openai')))) {
      brand = const WorkerPresentation(
          name: 'ChatGPT', iconAsset: 'assets/worker_icons/chatgpt.png');
    } else if (type == 'gemini' ||
        type.contains('gemini') ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('gemini') || nameLower.contains('google')))) {
      brand = const WorkerPresentation(
          name: 'Gemini', iconAsset: 'assets/worker_icons/gemini.png');
    } else if (type == 'claude' ||
        type == 'anthropic' ||
        type.contains('claude') ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('claude') ||
                nameLower.contains('anthropic')))) {
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
