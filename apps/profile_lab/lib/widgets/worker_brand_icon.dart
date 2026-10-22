import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

/// Bundled provider mark for a Worker, or null when the provider is unknown.
///
/// Matches on the Worker type, Profile definition, and provider tool name
/// only. Display and model names are never used to infer provider identity.
String? workerBrandIconAsset({
  required String workerTypeId,
  String? profileDefinitionId,
  String? providerToolName,
}) {
  final keys = [workerTypeId, profileDefinitionId, providerToolName]
      .whereType<String>()
      .map((value) => value.trim().toLowerCase())
      .where((value) => value.isNotEmpty)
      .toList();
  bool matches(List<String> tokens) =>
      keys.any((key) => tokens.any(key.contains));
  if (matches(const ['chatgpt', 'openai', 'codex'])) {
    return 'assets/worker_icons/chatgpt.png';
  }
  if (matches(const ['claude', 'anthropic'])) {
    return 'assets/worker_icons/claude.png';
  }
  if (matches(const ['gemini', 'google'])) {
    return 'assets/worker_icons/gemini.png';
  }
  return null;
}

/// A provider mark on a light tile so dark marks stay visible in dark mode.
/// Unknown Workers show the first letter of [name].
class WorkerBrandIcon extends StatelessWidget {
  const WorkerBrandIcon({
    required this.workerTypeId,
    required this.name,
    this.profileDefinitionId,
    this.providerToolName,
    this.size = 24,
    super.key,
  });

  final String workerTypeId;
  final String name;
  final String? profileDefinitionId;
  final String? providerToolName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = workerBrandIconAsset(
      workerTypeId: workerTypeId,
      profileDefinitionId: profileDefinitionId,
      providerToolName: providerToolName,
    );
    final colors = Theme.of(context).colorScheme;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * .14),
        decoration: BoxDecoration(
          color: asset == null ? colors.surfaceContainerHighest : Colors.white,
          borderRadius: BorderRadius.circular(size * .28),
          border: Border.all(color: ConclaveColors.borderDark),
        ),
        alignment: Alignment.center,
        child: asset == null
            ? Text(
                initial,
                style: TextStyle(
                  fontSize: size * .5,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant,
                ),
              )
            : Image.asset(
                asset,
                key: Key('worker-brand-icon-$workerTypeId'),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}
