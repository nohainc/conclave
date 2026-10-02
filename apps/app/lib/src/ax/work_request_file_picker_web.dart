// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

Future<List<Map<String, dynamic>>> pickWorkRequestFiles() async {
  final input = html.FileUploadInputElement()..multiple = true;
  input.click();
  await input.onChange.first;
  final files = input.files ?? const <html.File>[];
  if (files.length > 10 ||
      files.any((file) => file.size > 1024 * 1024) ||
      files.fold<int>(0, (sum, file) => sum + file.size) > 1024 * 1024) {
    throw const FormatException(
      'Choose up to 10 files, with each file and the total under 1 MB.',
    );
  }
  final result = <Map<String, dynamic>>[];
  for (final file in files) {
    final reader = html.FileReader()..readAsArrayBuffer(file);
    await reader.onLoad.first;
    final data = reader.result;
    if (data is! ByteBuffer) continue;
    final bytes = data.asUint8List();
    result.add({
      'kind': 'file',
      'name': file.name,
      'mediaType': file.type.isEmpty ? 'application/octet-stream' : file.type,
      'sizeBytes': bytes.length,
      'contentBase64': base64Encode(bytes),
    });
  }
  return result;
}
