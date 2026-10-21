@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/work_request_file_picker_web.dart';

void main() {
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
}
