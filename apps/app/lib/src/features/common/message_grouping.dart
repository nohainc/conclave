import 'package:flutter/material.dart';

/// Group only adjacent, confirmed messages with a stable author identity.
bool continuesMessageGroup({
  required String? authorId,
  required String? previousAuthorId,
  required DateTime? sentAt,
  required DateTime? previousSentAt,
  bool confirmed = true,
  bool previousConfirmed = true,
}) {
  if (!confirmed ||
      !previousConfirmed ||
      authorId == null ||
      authorId.isEmpty ||
      authorId != previousAuthorId ||
      sentAt == null ||
      previousSentAt == null ||
      !sameMessageDay(sentAt, previousSentAt)) {
    return false;
  }
  final gap = sentAt.difference(previousSentAt);
  return !gap.isNegative && gap <= const Duration(minutes: 10);
}

bool sameMessageDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Dates are supplied in the viewer's local timezone. Unknown dates stay unlabelled.
class MessageDayBoundary extends StatelessWidget {
  const MessageDayBoundary({
    super.key,
    required this.date,
    required this.previousDate,
    required this.child,
  });

  final DateTime? date;
  final DateTime? previousDate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final day = date;
    if (day == null ||
        (previousDate != null && sameMessageDay(day, previousDate!))) {
      return child;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                MaterialLocalizations.of(context).formatMediumDate(day),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            const Expanded(child: Divider()),
          ]),
        ),
        child,
      ],
    );
  }
}
