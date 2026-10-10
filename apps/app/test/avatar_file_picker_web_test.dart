@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:conclave_app/src/ax/avatar_file_picker_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads original PNG bytes from a browser file', () async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');
    final file = html.File(
        [Uint8List.fromList(bytes)], 'avatar.png', {'type': 'image/png'});
    final result = await readAvatarFile(file);
    expect(result.bytes, bytes);
    expect(result.mediaType, 'image/png');
  });

  test('rejects unsupported files before reading', () async {
    final file = html.File(['text'], 'avatar.txt', {'type': 'text/plain'});
    await expectLater(readAvatarFile(file), throwsStateError);
  });
}
