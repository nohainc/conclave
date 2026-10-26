import 'package:flutter/material.dart' show Brightness;

/// Product branding only. Execution options come from Worker Profiles.
class WorkerPresentation {
  const WorkerPresentation({required this.name, this.iconAsset});

  final String name;
  final String? iconAsset;

  /// Selects the bundled mark for the current surface theme.
  String? iconAssetForBrightness(Brightness brightness) =>
      assetForBrightness(iconAsset, brightness);

  static String? assetForBrightness(
    String? iconAsset,
    Brightness brightness,
  ) {
    for (final worker in ['copilot', 'grok']) {
      if (iconAsset == 'assets/worker_icons/$worker.png') {
        final theme = brightness == Brightness.dark ? 'dark' : 'light';
        return 'assets/worker_icons/$worker-$theme.png';
      }
    }
    return iconAsset;
  }

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
    if (matches(const ['chatgpt', 'openai']) ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('chatgpt') || nameLower.contains('openai')))) {
      brand = const WorkerPresentation(
          name: 'ChatGPT', iconAsset: 'assets/worker_icons/chatgpt.png');
    } else if (matches(const ['gemini', 'google', 'agy']) ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('gemini') || nameLower.contains('google')))) {
      brand = const WorkerPresentation(
          name: 'Gemini', iconAsset: 'assets/worker_icons/gemini.png');
    } else if (matches(const ['claude', 'anthropic']) ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            (nameLower.contains('claude') ||
                nameLower.contains('anthropic')))) {
      brand = const WorkerPresentation(
          name: 'Claude', iconAsset: 'assets/worker_icons/claude.png');
    } else if (matches(const ['copilot']) ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            nameLower.contains('copilot'))) {
      brand = const WorkerPresentation(
          name: 'Copilot', iconAsset: 'assets/worker_icons/copilot.png');
    } else if (matches(const ['grok', 'xai']) ||
        ((type.isEmpty || type == 'custom' || type == 'worker') &&
            nameLower.contains('grok'))) {
      brand = const WorkerPresentation(
          name: 'Grok', iconAsset: 'assets/worker_icons/grok.png');
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
