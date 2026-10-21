// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

Future<List<Map<String, dynamic>>> pickWorkRequestFiles() async {
  // Attach the input to the DOM and listen before clicking: detached inputs
  // can drop the change event in some browsers, leaving the selection unseen.
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..style.display = 'none';
  final selected = Completer<List<html.File>>();
  input.onChange.first.then((_) {
    if (!selected.isCompleted) selected.complete(input.files ?? <html.File>[]);
  });
  input.addEventListener('cancel', (_) {
    if (!selected.isCompleted) selected.complete(<html.File>[]);
  });
  html.document.body?.append(input);
  input.click();
  final List<html.File> files;
  try {
    files = await selected.future;
  } finally {
    input.remove();
  }
  return readWorkRequestFiles(files);
}

/// Reads browser files into the bounded request attachment payload.
Future<List<Map<String, dynamic>>> readWorkRequestFiles(
    List<html.File> files) async {
  if (files.length > 10 || files.any((file) => file.size > 2 * 1024 * 1024)) {
    throw const FormatException(
      'Choose up to 10 files, each under 2 MB.',
    );
  }
  final result = <Map<String, dynamic>>[];
  for (final file in files) {
    final reader = html.FileReader();
    final loaded = Completer<void>();
    final load = reader.onLoad.listen((_) {
      if (!loaded.isCompleted) loaded.complete();
    });
    final error = reader.onError.listen((_) {
      if (!loaded.isCompleted) {
        loaded.completeError(FormatException('Could not read "${file.name}".'));
      }
    });
    final abort = reader.onAbort.listen((_) {
      if (!loaded.isCompleted) {
        loaded.completeError(
            FormatException('Reading "${file.name}" was cancelled.'));
      }
    });
    try {
      reader.readAsArrayBuffer(file);
      await loaded.future;
    } finally {
      await load.cancel();
      await error.cancel();
      await abort.cancel();
    }
    final data = reader.result;
    final Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is ByteBuffer) {
      bytes = data.asUint8List();
    } else {
      throw FormatException('Could not read "${file.name}".');
    }
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
