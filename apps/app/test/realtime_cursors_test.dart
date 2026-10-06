import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/realtime/realtime_cursors.dart';

void main() {
  test('same ID has independent Project, user and execution cursors', () {
    final cursors = RealtimeCursors();
    cursors.record({'workspaceId': 'same', 'sequence': 10});
    cursors.record({
      'stream': {'kind': 'project', 'id': 'same'},
      'sequence': 2
    });
    cursors.record({
      'stream': {'kind': 'user', 'id': 'same'},
      'sequence': 4
    });
    expect(cursors.hello(), {
      'type': 'realtime.hello',
      'lastDurableSequences': {'same': 10},
      'lastDurableStreamSequences': {
        '["execution_workspace","same"]': 10,
        '["project","same"]': 2,
        '["user","same"]': 4
      }
    });
  });
  test('gap frames advance only their stream and older frames cannot regress',
      () {
    final cursors = RealtimeCursors();
    cursors.record({
      'stream': {'kind': 'project', 'id': 'P'},
      'nextSequence': 5
    });
    cursors.record({
      'stream': {'kind': 'project', 'id': 'P'},
      'sequence': 2
    });
    expect(
        cursors.hello()['lastDurableStreamSequences'], {'["project","P"]': 5});
    expect(cursors.hello().containsKey('lastDurableSequences'), isFalse);
  });
  test('hello returns detached maps and malformed sequences are ignored', () {
    final cursors = RealtimeCursors();
    cursors.record({'workspaceId': 'W', 'sequence': -1});
    expect(cursors.hello(), {'type': 'realtime.hello'});
    cursors.record({'workspaceId': 'W', 'sequence': 1});
    (cursors.hello()['lastDurableSequences'] as Map).clear();
    expect(cursors.hello()['lastDurableSequences'], {'W': 1});
  });
}
