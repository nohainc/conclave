import 'package:syntila_app/src/ax/attachment_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('admits every file within the count and size limits', () {
    final admission = admitAttachments(existing: 0, candidates: [
      (name: 'a.txt', sizeBytes: 1),
      (name: 'b.png', sizeBytes: 10 * 1024 * 1024),
    ]);
    expect(admission.accepted, [0, 1]);
    expect(admission.notice, isNull);
  });

  test('skips oversized files individually and keeps the rest', () {
    final admission = admitAttachments(existing: 0, candidates: [
      (name: 'big.mov', sizeBytes: maxAttachmentBytes + 1),
      (name: 'ok.txt', sizeBytes: 5),
    ]);
    expect(admission.accepted, [1]);
    expect(admission.notice, 'Skipped 1 file: "big.mov" is over 10 MB.');
  });

  test('fills only the remaining slots and summarises long skip lists', () {
    final admission = admitAttachments(existing: 7, candidates: [
      for (var i = 0; i < 8; i++) (name: 'f$i', sizeBytes: 1),
    ]);
    expect(admission.accepted, [0, 1, 2]);
    expect(admission.skipped, hasLength(5));
    expect(admission.notice, startsWith('Skipped 5 files: "f3" exceeds'));
    expect(admission.notice, endsWith('and 2 more.'));
  });

  test('a full request admits nothing', () {
    final admission = admitAttachments(
        existing: maxAttachmentCount, candidates: [(name: 'x', sizeBytes: 1)]);
    expect(admission.accepted, isEmpty);
    expect(admission.skipped, hasLength(1));
  });
}
