// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

class AxAvatarFile {
  const AxAvatarFile({required this.bytes, required this.mediaType});

  final List<int> bytes;
  final String mediaType;
}

Future<AxAvatarFile?> pickAvatarFile() async {
  final input = html.FileUploadInputElement()
    ..accept = 'image/png,image/jpeg,image/gif,image/webp'
    ..multiple = false;
  input.click();
  await input.onChange.first;
  final file = input.files?.firstOrNull;
  if (file == null) return null;
  if (file.size > 5 * 1024 * 1024) {
    throw StateError('Avatar image must be 5 MB or smaller.');
  }
  const supported = {'image/png', 'image/jpeg', 'image/gif', 'image/webp'};
  final mediaType = file.type.toLowerCase();
  if (!supported.contains(mediaType)) {
    throw StateError('Choose a PNG, JPEG, GIF, or WebP image.');
  }
  final reader = html.FileReader();
  final completer = Completer<AxAvatarFile>();
  reader.onLoad.listen((_) {
    final result = reader.result;
    if (result is String) {
      final separator = result.indexOf(',');
      if (separator >= 0) {
        try {
          completer.complete(AxAvatarFile(
            bytes: base64Decode(result.substring(separator + 1)),
            mediaType: mediaType,
          ));
          return;
        } on FormatException {
          // Fall through to the shared read error.
        }
      }
    }
    if (!completer.isCompleted) {
      completer.completeError(StateError('Could not read the avatar image.'));
    }
  });
  reader.onError.listen((_) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('Could not read the avatar image.'));
    }
  });
  reader.readAsDataUrl(file);
  return completer.future;
}

extension on List<html.File> {
  html.File? get firstOrNull => isEmpty ? null : first;
}
