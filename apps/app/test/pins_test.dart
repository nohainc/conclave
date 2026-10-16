import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/ax/ax_models.dart';

AxThread _thread(String id, {String pinnedAt = '', String status = 'active'}) =>
    AxThread.fromJson({
      'id': id,
      'spaceId': 'S',
      'name': id,
      'status': status,
      'pinnedAt': pinnedAt,
    });

void main() {
  test('pins come from Cloud JSON and survive copyWith', () {
    final thread = _thread('a', pinnedAt: '2026-10-01T00:00:00Z');
    expect(thread.isPinned, isTrue);
    expect(thread.copyWith(hasUnread: true).isPinned, isTrue);
    expect(thread.copyWith(pinnedAt: '').isPinned, isFalse);
    final space = AxSpace.fromJson(
        {'id': 'S', 'name': 'S', 'pinnedAt': '2026-10-01T00:00:00Z'});
    expect(space.isPinned, isTrue);
    expect(space.copyWith(name: 'T').isPinned, isTrue);
    expect(AxSpace.fromJson({'id': 'S', 'name': 'S'}).isPinned, isFalse);
    // Cloud sends null for unpinned items.
    expect(
        AxSpace.fromJson({'id': 'S', 'name': 'S', 'pinnedAt': null}).isPinned,
        isFalse);
    expect(
        AxThread.fromJson({'id': 'T', 'spaceId': 'S', 'pinnedAt': null})
            .isPinned,
        isFalse);
  });

  test('pinned Threads lead, newest pin first; others keep their order', () {
    final ordered = applyAxThreadPins([
      _thread('x'),
      _thread('old', pinnedAt: '2026-10-01T00:00:00Z'),
      _thread('y'),
      _thread('new', pinnedAt: '2026-10-02T00:00:00Z'),
      _thread('gone', pinnedAt: '2026-10-03T00:00:00Z', status: 'archived'),
    ]);
    expect(ordered.map((t) => t.id), ['new', 'old', 'x', 'y', 'gone']);
  });

  test('manual pin order beats pin time; new pins go on top', () {
    AxThread pin(String id, int position, String at) => AxThread.fromJson({
          'id': id,
          'spaceId': 'S',
          'pinnedAt': at,
          'pinPosition': position,
        });
    final ordered = applyAxThreadPins([
      pin('b', 1, '2026-10-03T00:00:00Z'),
      pin('a', 0, '2026-10-01T00:00:00Z'),
      pin('tie2', 5, '2026-10-01T00:00:00Z'),
      pin('tie1', 5, '2026-10-02T00:00:00Z'),
    ]);
    expect(ordered.map((t) => t.id), ['a', 'b', 'tie1', 'tie2']);
    expect(nextAxPinPosition(const []), 0);
    expect(nextAxPinPosition(const [0, 3, -2]), -3);
    expect(
        AxSpace.fromJson({'id': 'S', 'name': 'S', 'pinPosition': 4})
            .copyWith(name: 'T')
            .pinPosition,
        4);
  });
}
