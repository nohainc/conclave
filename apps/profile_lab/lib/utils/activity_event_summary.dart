/// Formats Cloud audit facts without treating unknown identities as resolved people.
String activityEventSummary(Map<String, dynamic> event,
    {required String workerName, String? actorName}) {
  final version = event['releaseVersion'];
  final subject = '$workerName${version == null ? '' : ' v$version'}';
  final channel = event['channel'] ?? event['toState'];
  final destination = channel == null || channel.toString().isEmpty
      ? 'a channel'
      : '${channel.toString()[0].toUpperCase()}${channel.toString().substring(1)}';
  final action = event['action'];
  final description = switch (action) {
    'draft_created' => '$subject Draft created',
    'draft_updated' => '$subject Draft saved to Cloud',
    'published_for_testing' => '$subject published for Testing',
    'promoted_to_beta' => '$subject promoted to Beta',
    'promoted_to_stable' => '$subject promoted to Stable',
    'promoted' ||
    'channel_promoted' ||
    'release.promoted' =>
      '$subject promoted to $destination',
    'rolled_back' ||
    'stable_rollback' =>
      '$destination rolled back to $subject${event['previousReleaseVersion'] == null ? '' : ' from v${event['previousReleaseVersion']}'}',
    'channel_cleared' => '$destination channel cleared for $workerName',
    'revoked' => '$subject revoked',
    'retired' => '$subject retired',
    'evidence_submitted' => 'Acceptance evidence recorded for $subject',
    _ =>
      '$subject: ${action == null ? 'Activity recorded' : action.toString().replaceAll(RegExp(r'[_.]'), ' ')}',
  };
  return '$description by ${actorName ?? (event['actorUserId'] == null ? 'System' : 'an operator')}';
}
