/// Per-request attachment limits shared by the Ask AI and Message composers.
/// Cloud enforces the same bounds; these only give earlier, per-file feedback.
const maxAttachmentCount = 10;
const maxAttachmentBytes = 10 * 1024 * 1024;

/// Which of a multi-file selection fit alongside [existing] attachments.
class AttachmentAdmission {
  const AttachmentAdmission(this.accepted, this.skipped);

  /// Indexes into the candidate list, in selection order.
  final List<int> accepted;

  /// Human-readable reasons, one per skipped file.
  final List<String> skipped;

  /// A single notice for the skipped files, or null when all were admitted.
  String? get notice {
    if (skipped.isEmpty) return null;
    const shown = 3;
    final listed = skipped.take(shown).join('; ');
    final more =
        skipped.length > shown ? ' and ${skipped.length - shown} more' : '';
    return 'Skipped ${skipped.length} '
        '${skipped.length == 1 ? 'file' : 'files'}: $listed$more.';
  }
}

/// Admits files in order: oversized files are skipped individually, and
/// files beyond the remaining slots are skipped without rejecting the rest.
AttachmentAdmission admitAttachments({
  required int existing,
  required List<({String name, int sizeBytes})> candidates,
}) {
  final accepted = <int>[];
  final skipped = <String>[];
  for (final (index, file) in candidates.indexed) {
    if (file.sizeBytes > maxAttachmentBytes) {
      skipped.add('"${file.name}" is over 10 MB');
    } else if (existing + accepted.length >= maxAttachmentCount) {
      skipped.add('"${file.name}" exceeds the $maxAttachmentCount-file limit');
    } else {
      accepted.add(index);
    }
  }
  return AttachmentAdmission(accepted, skipped);
}
