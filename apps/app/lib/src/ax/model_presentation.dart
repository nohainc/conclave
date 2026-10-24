import 'package:flutter/material.dart' show Brightness;

import 'worker_presentation.dart';

enum ModelFamily {
  chatgpt,
  claude,
  gemini,
  grok,
  unknown;

  String get displayName => switch (this) {
        ModelFamily.chatgpt => 'ChatGPT',
        ModelFamily.claude => 'Claude',
        ModelFamily.gemini => 'Gemini',
        ModelFamily.grok => 'Grok',
        ModelFamily.unknown => 'Model',
      };
}

/// Branding and presentation resolution for execution models.
/// Resolves model family, icon asset, and short/clean model name/version.
class ModelPresentation {
  const ModelPresentation({
    required this.name,
    required this.shortName,
    this.iconAsset,
    this.family = ModelFamily.unknown,
  });

  /// Full model name with version (e.g. "Claude Opus", "GPT-6-Sol", "Claude 3.5 Sonnet", "Gemini 3.8 Flash", "Grok 4.7").
  final String name;

  /// Model name stripped of provider/family identity prefix (e.g. "Opus", "6-Sol", "Opus 5.5", "3.8 Flash", "4.7").
  final String shortName;

  /// Bundled icon asset, e.g. 'assets/worker_icons/claude.png'.
  final String? iconAsset;

  final ModelFamily family;

  /// Selects the bundled mark for the current surface theme (handles Grok dark/light variants).
  String? iconAssetForBrightness(Brightness brightness) {
    if (iconAsset == 'assets/worker_icons/grok.png') {
      final theme = brightness == Brightness.dark ? 'dark' : 'light';
      return 'assets/worker_icons/grok-$theme.png';
    }
    return iconAsset;
  }

  static final RegExp _identityPrefix = RegExp(
    r'^(chatgpt|openai|anthropic|gpt|claude|gemini|grok)[\s\-_:]*',
    caseSensitive: false,
  );

  /// Identifies the model family based on starts-with rules and token containment.
  static ModelFamily detectFamily(String? modelId, [String? modelName]) {
    final rawId = modelId?.trim().toLowerCase() ?? '';
    final rawName = modelName?.trim().toLowerCase() ?? '';

    // Primary rule from specification:
    // GPT -> ChatGPT model; Claude -> Claude; Gemini -> Gemini; Grok -> Grok.
    if (rawName.startsWith('gpt') ||
        rawName.startsWith('chatgpt') ||
        rawName.startsWith('openai') ||
        rawId.startsWith('gpt') ||
        rawId.startsWith('chatgpt') ||
        rawId.startsWith('openai') ||
        rawId.startsWith('o1') ||
        rawId.startsWith('o3')) {
      return ModelFamily.chatgpt;
    }
    if (rawName.startsWith('claude') || rawId.startsWith('claude')) {
      return ModelFamily.claude;
    }
    if (rawName.startsWith('gemini') || rawId.startsWith('gemini')) {
      return ModelFamily.gemini;
    }
    if (rawName.startsWith('grok') || rawId.startsWith('grok')) {
      return ModelFamily.grok;
    }

    // Secondary token matches (e.g., "anthropic-claude" or nested tokens)
    if (rawName.contains('claude') || rawId.contains('claude')) {
      return ModelFamily.claude;
    }
    if (rawName.contains('gemini') || rawId.contains('gemini')) {
      return ModelFamily.gemini;
    }
    if (rawName.contains('grok') || rawId.contains('grok')) {
      return ModelFamily.grok;
    }
    if (rawName.contains('gpt') ||
        rawName.contains('chatgpt') ||
        rawId.contains('gpt') ||
        rawId.contains('chatgpt')) {
      return ModelFamily.chatgpt;
    }

    return ModelFamily.unknown;
  }

  /// Strips the brand identity prefix, returning only the model name or version.
  /// Examples:
  /// - "Claude Opus" -> "Opus"
  /// - "GPT-6-Sol" -> "6-Sol"
  /// - "Claude Opus 5.5" -> "Opus 5.5"
  /// - "Gemini 3.8 Flash" -> "3.8 Flash"
  /// - "Grok 4.7" -> "4.7"
  static String stripIdentity(String name) {
    final stripped = name.replaceFirst(_identityPrefix, '').trim();
    return stripped.isNotEmpty ? stripped : name.trim();
  }

  /// Resolves the ModelPresentation from model ID, model display name, and fallback worker info.
  static ModelPresentation resolve({
    String? modelId,
    String? modelDisplayName,
    String? fallbackWorkerTypeId,
    String? fallbackWorkerDisplayName,
  }) {
    final effectiveModelId = modelId?.trim();
    final effectiveModelName = modelDisplayName?.trim();
    final rawName =
        (effectiveModelName != null && effectiveModelName.isNotEmpty)
            ? effectiveModelName
            : ((effectiveModelId != null && effectiveModelId.isNotEmpty)
                ? effectiveModelId
                : null);

    var family = detectFamily(effectiveModelId, rawName);

    // If model family cannot be detected from model ID/name, check worker fallback
    if (family == ModelFamily.unknown &&
        (fallbackWorkerTypeId != null || fallbackWorkerDisplayName != null)) {
      final workerType = fallbackWorkerTypeId?.trim().toLowerCase() ?? '';
      final workerName = fallbackWorkerDisplayName?.trim().toLowerCase() ?? '';
      if (workerType.contains('chatgpt') ||
          workerType.contains('openai') ||
          workerName.contains('chatgpt') ||
          workerName.contains('openai')) {
        family = ModelFamily.chatgpt;
      } else if (workerType.contains('claude') ||
          workerType.contains('anthropic') ||
          workerName.contains('claude') ||
          workerName.contains('anthropic')) {
        family = ModelFamily.claude;
      } else if (workerType.contains('gemini') ||
          workerType.contains('google') ||
          workerName.contains('gemini') ||
          workerName.contains('google')) {
        family = ModelFamily.gemini;
      } else if (workerType.contains('grok') ||
          workerType.contains('xai') ||
          workerName.contains('grok')) {
        family = ModelFamily.grok;
      }
    }

    String? iconAsset;
    switch (family) {
      case ModelFamily.chatgpt:
        iconAsset = 'assets/worker_icons/chatgpt.png';
        break;
      case ModelFamily.claude:
        iconAsset = 'assets/worker_icons/claude.png';
        break;
      case ModelFamily.gemini:
        iconAsset = 'assets/worker_icons/gemini.png';
        break;
      case ModelFamily.grok:
        iconAsset = 'assets/worker_icons/grok.png';
        break;
      case ModelFamily.unknown:
        if (fallbackWorkerTypeId != null || fallbackWorkerDisplayName != null) {
          iconAsset = WorkerPresentation.resolve(
                  fallbackWorkerTypeId, fallbackWorkerDisplayName)
              .iconAsset;
        }
        break;
    }

    final effectiveName = rawName ??
        (fallbackWorkerDisplayName?.trim().isNotEmpty == true
            ? fallbackWorkerDisplayName!.trim()
            : (family != ModelFamily.unknown ? family.displayName : 'Model'));

    final shortName = stripIdentity(effectiveName);

    return ModelPresentation(
      name: effectiveName,
      shortName: shortName,
      iconAsset: iconAsset,
      family: family,
    );
  }
}
