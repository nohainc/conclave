import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'profile_domain_diff.dart';

/// Provenance metadata tracking human vs. AI authorship of Tool Profile drafts.
class AiProvenance {
  const AiProvenance({
    required this.authorType, // 'human', 'ai_assistant', 'ai_repair_loop', 'ai_auto_repair'
    this.modelIdentifier,
    this.parentDigest,
    this.parentReleaseVersion,
    this.taskIdentifier,
    this.diffDigest,
    this.reviewedBy,
    this.actor,
  });

  final String authorType;
  final String? modelIdentifier;
  final String? parentDigest;
  final int? parentReleaseVersion;
  final String? taskIdentifier;
  final String? diffDigest;
  final String? reviewedBy;
  final String? actor;

  bool get isAiAssisted => authorType.startsWith('ai_');

  Map<String, dynamic> toJson() => {
        'authorType': authorType,
        if (modelIdentifier != null) 'modelIdentifier': modelIdentifier,
        if (parentDigest != null) 'parentDigest': parentDigest,
        if (parentReleaseVersion != null)
          'parentReleaseVersion': parentReleaseVersion,
        if (taskIdentifier != null) 'taskIdentifier': taskIdentifier,
        if (diffDigest != null) 'diffDigest': diffDigest,
        if (reviewedBy != null) 'reviewedBy': reviewedBy,
        if (actor != null) 'actor': actor,
      };

  factory AiProvenance.fromJson(Map<String, dynamic> json) {
    return AiProvenance(
      authorType: json['authorType'] as String? ?? 'human',
      modelIdentifier: json['modelIdentifier'] as String?,
      parentDigest: json['parentDigest'] as String?,
      parentReleaseVersion: json['parentReleaseVersion'] as int?,
      taskIdentifier: json['taskIdentifier'] as String?,
      diffDigest: json['diffDigest'] as String?,
      reviewedBy: json['reviewedBy'] as String?,
      actor: json['actor'] as String?,
    );
  }

  /// Calculates sha256 hex digest of domain diff groups.
  static String computeDiffDigest(List<DomainDiffGroup> diffs) {
    final changedItems = <Map<String, String?>>[];
    for (final group in diffs) {
      for (final item in group.items) {
        if (item.changeType != DiffChangeType.unchanged) {
          changedItems.add({
            'path': item.fieldPath,
            'valA': item.valueA,
            'valB': item.valueB,
          });
        }
      }
    }
    final encoded = jsonEncode(changedItems);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  /// Formats human-readable audit provenance summary string.
  /// Example: "Draft v20 created by experimental heuristic suggestion (experimental-local-heuristic, parent: a1b2c3d4), reviewed by Vitalii."
  String formatAuditSummary({
    required int releaseVersion,
    String? testedProviderVersion,
    String? publishedBy,
    String? promotedBy,
    String? channel,
  }) {
    final isExperimentalHeuristic =
        modelIdentifier == 'experimental-local-heuristic';
    final changeKind = isExperimentalHeuristic
        ? 'experimental heuristic suggestion'
        : isAiAssisted
            ? 'AI-assisted change'
            : 'manual human edit';
    final modelInfo =
        isAiAssisted && modelIdentifier != null ? ' ($modelIdentifier' : '';
    final parentInfo = parentDigest != null
        ? '${modelInfo.isNotEmpty ? ", " : " ("}parent: ${parentDigest!.length > 8 ? parentDigest!.substring(0, 8) : parentDigest}'
        : '';
    final closeParen =
        (modelInfo.isNotEmpty || parentInfo.isNotEmpty) ? ')' : '';

    final reviewerStr = reviewedBy != null ? ', reviewed by $reviewedBy' : '';
    final testedStr = testedProviderVersion != null
        ? ', tested on $testedProviderVersion'
        : '';
    final publishedStr =
        publishedBy != null ? ', published by $publishedBy' : '';
    final promotedStr = promotedBy != null && channel != null
        ? ', promoted to $channel by $promotedBy'
        : '';

    return 'Draft v$releaseVersion created by $changeKind$modelInfo$parentInfo$closeParen$reviewerStr$testedStr$publishedStr$promotedStr.';
  }
}
