import 'package:syntila_app/src/features/common/message_grouping.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 17, 12);
  bool grouped({
    String? author = 'a',
    String? previousAuthor = 'a',
    DateTime? date,
    bool confirmed = true,
    bool previousConfirmed = true,
  }) =>
      continuesMessageGroup(
        authorId: author,
        previousAuthorId: previousAuthor,
        sentAt: date ?? start.add(const Duration(minutes: 10)),
        previousSentAt: start,
        confirmed: confirmed,
        previousConfirmed: previousConfirmed,
      );

  test('same-author spacing stays tight even when time breaks grouping', () {
    expect(grouped(date: start.add(const Duration(minutes: 30))), isFalse);
    expect(messageAuthorSpacing('a', 'a'), 2);
    expect(messageAuthorSpacing('b', 'a'), 20);
    expect(messageAuthorSpacing(null, null), 20);
    expect(messageAuthorSpacing('', ''), 20);
  });

  test('adjacent same-author messages group up to ten minutes', () {
    expect(grouped(), isTrue);
    expect(grouped(date: start), isTrue);
    expect(grouped(date: start.add(const Duration(minutes: 10, seconds: 1))),
        isFalse);
    expect(grouped(date: start.subtract(const Duration(seconds: 1))), isFalse);
  });

  test('identity, optimistic state and missing dates break groups', () {
    expect(grouped(author: 'b'), isFalse);
    expect(grouped(author: null), isFalse);
    expect(grouped(author: '', previousAuthor: ''), isFalse);
    expect(grouped(confirmed: false), isFalse);
    expect(grouped(previousConfirmed: false), isFalse);
    expect(
        continuesMessageGroup(
            authorId: 'a',
            previousAuthorId: 'a',
            sentAt: null,
            previousSentAt: start),
        isFalse);
  });

  test('midnight breaks groups even with a short gap', () {
    expect(
        continuesMessageGroup(
            authorId: 'a',
            previousAuthorId: 'a',
            sentAt: DateTime(2026, 10, 18, 0, 1),
            previousSentAt: DateTime(2026, 10, 17, 23, 59)),
        isFalse);
  });

  testWidgets('day boundaries label only the first message of a local day',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      MessageDayBoundary(
          date: start, previousDate: null, child: const Text('first')),
      MessageDayBoundary(
          date: start.add(const Duration(minutes: 1)),
          previousDate: start,
          child: const Text('second')),
      MessageDayBoundary(
          date: start.add(const Duration(days: 1)),
          previousDate: start,
          child: const Text('third')),
      const MessageDayBoundary(
          date: null, previousDate: null, child: Text('unknown')),
    ]))));
    expect(find.byType(Divider), findsNWidgets(4));
    for (final text in ['first', 'second', 'third', 'unknown']) {
      expect(find.text(text), findsOneWidget);
    }
  });
}
