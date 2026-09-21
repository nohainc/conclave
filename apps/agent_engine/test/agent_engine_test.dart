import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Agent Engine scaffold has a native Dart runtime', () {
    expect(Platform.operatingSystem, isNotEmpty);
  });
}
