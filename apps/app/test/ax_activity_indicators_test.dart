import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Thread and Space parse server activity flags, defaulting to off', () {
    final thread = AxThread.fromJson({
      'id': 't',
      'spaceId': 's',
      'name': 'T',
      'hasActiveWork': true,
      'hasUnread': true,
    });
    expect(thread.hasActiveWork, isTrue);
    expect(thread.hasUnread, isTrue);
    expect(thread.copyWith(hasUnread: false).hasUnread, isFalse);
    expect(thread.copyWith(name: 'Renamed').hasUnread, isTrue);
    expect(thread.copyWith(name: 'Renamed').hasActiveWork, isTrue);

    final plain = AxThread.fromJson({'id': 't', 'spaceId': 's', 'name': 'T'});
    expect(plain.hasActiveWork, isFalse);
    expect(plain.hasUnread, isFalse);

    final space = AxSpace.fromJson(
        {'id': 's', 'name': 'S', 'hasActiveWork': true, 'hasUnread': true});
    expect(space.hasActiveWork, isTrue);
    expect(space.copyWith(name: 'Renamed').hasUnread, isTrue);
    expect(AxSpace.fromJson({'id': 's', 'name': 'S'}).hasUnread, isFalse);
  });
}
