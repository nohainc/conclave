/// Product branding only. Execution capabilities come from Worker descriptors.
class WorkerPresentation {
  const WorkerPresentation({required this.name, this.iconAsset});

  final String name;
  final String? iconAsset;

  static WorkerPresentation resolve(String? workerTypeId, String? displayName) {
    final brand = switch (workerTypeId?.trim().toLowerCase()) {
      'chatgpt' => const WorkerPresentation(
          name: 'ChatGPT', iconAsset: 'assets/worker_icons/chatgpt.png'),
      'gemini' => const WorkerPresentation(
          name: 'Gemini', iconAsset: 'assets/worker_icons/gemini.png'),
      'claude' => const WorkerPresentation(
          name: 'Claude', iconAsset: 'assets/worker_icons/claude.png'),
      _ => const WorkerPresentation(name: 'Worker'),
    };
    return WorkerPresentation(
      name: displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : brand.name,
      iconAsset: brand.iconAsset,
    );
  }
}
