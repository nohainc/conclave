@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/work_request_file_picker_web.dart';

void main() {
  test(
      'image files include a bounded JPEG thumbnail without changing original bytes',
      () async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=');
    final files = await readWorkRequestFiles([
      html.File([bytes], 'pixel.png', {'type': 'image/png'})
    ]);
    expect(base64Decode(files.single['contentBase64']), bytes);
    expect(files.single['previewImage'], startsWith('/9j/'));
    expect((files.single['previewImage'] as String).length,
        lessThanOrEqualTo(32000));
  });
  test('browser FileReader preserves selected file bytes and metadata',
      () async {
    final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
    final attachments = await readWorkRequestFiles([
      html.File([bytes], 'example.bin', {'type': 'application/octet-stream'}),
      html.File(['hello'], 'note.txt', {'type': 'text/plain'}),
    ]);
    expect(attachments, hasLength(2));
    expect(attachments.first, {
      'kind': 'file',
      'name': 'example.bin',
      'mediaType': 'application/octet-stream',
      'sizeBytes': bytes.length,
      'contentBase64': base64Encode(bytes),
    });
    expect(
        utf8.decode(base64Decode(attachments.last['contentBase64'])), 'hello');
  });

  test('empty selection and empty files are handled', () async {
    expect(await readWorkRequestFiles([]), isEmpty);
    final attachments = await readWorkRequestFiles([html.File([], 'empty')]);
    expect(attachments.single['sizeBytes'], 0);
    expect(attachments.single['contentBase64'], '');
  });

  test('file count and size limits reject selection', () async {
    await expectLater(
      readWorkRequestFiles(List.generate(11, (_) => html.File([], 'empty'))),
      throwsFormatException,
    );
    await expectLater(
      readWorkRequestFiles([
        html.File([Uint8List(2 * 1024 * 1024 + 1)], 'large'),
      ]),
      throwsFormatException,
    );
  });

  test('large images get a sharp 256 px square thumbnail', () async {
    final canvas = html.CanvasElement(width: 1200, height: 600);
    canvas.context2D
      ..setFillColorRgb(200, 30, 30)
      ..fillRect(0, 0, 1200, 600);
    final png = base64Decode(canvas.toDataUrl('image/png').split(',').last);
    final file = (await readWorkRequestFiles([
      html.File([png], 'wide.png', {'type': 'image/png'})
    ]))
        .single;
    final preview = file['previewImage'] as String;
    expect(preview, startsWith('/9j/'));
    expect(preview.length, lessThanOrEqualTo(32000));
    final image = html.ImageElement(src: 'data:image/jpeg;base64,$preview');
    await image.onLoad.first;
    expect([image.naturalWidth, image.naturalHeight], [256, 256]);
  });

  test('small JPEGs are reused as their own thumbnail', () async {
    final canvas = html.CanvasElement(width: 64, height: 64);
    canvas.context2D
      ..setFillColorRgb(30, 30, 200)
      ..fillRect(0, 0, 64, 64);
    final jpeg = canvas.toDataUrl('image/jpeg', 0.9).split(',').last;
    final file = (await readWorkRequestFiles([
      html.File([base64Decode(jpeg)], 'small.jpg', {'type': 'image/jpeg'})
    ]))
        .single;
    expect(file['previewImage'], jpeg);
  });
}
