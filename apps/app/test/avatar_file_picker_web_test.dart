@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:syntila_app/src/ax/avatar_file_picker_web.dart';
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
    expect(result.thumbnailBytes, isNotEmpty);
    expect(result.thumbnailBytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
  });

  test('shrinks a large image and preserves the original file', () async {
    final canvas = html.CanvasElement(width: 800, height: 400);
    canvas.context2D.fillRect(0, 0, 800, 400);
    final blob = await canvas.toBlob('image/png');
    final result = await readAvatarFile(
        html.File([blob], 'large.png', {'type': 'image/png'}));
    final url = html.Url.createObjectUrl(
        html.Blob([Uint8List.fromList(result.thumbnailBytes)]));
    try {
      final image = html.ImageElement(src: url);
      await image.onLoad.first;
      expect(image.naturalWidth, 128);
      expect(image.naturalHeight, 64);
      expect(result.bytes.length, greaterThan(result.thumbnailBytes.length));
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  });

  test('rejects unsupported files before reading', () async {
    final file = html.File(['text'], 'avatar.txt', {'type': 'text/plain'});
    await expectLater(readAvatarFile(file), throwsStateError);
  });
}
