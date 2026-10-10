// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

class AxAvatarFile {
  const AxAvatarFile({required this.bytes, required this.mediaType});

  final List<int> bytes;
  final String mediaType;
}

Future<AxAvatarFile?> pickAvatarFile() async {
  final input = html.FileUploadInputElement()
    ..accept = 'image/png,image/jpeg,image/gif,image/webp'
    ..multiple = false;
  final selection = input.onChange.first;
  input.click();
  await selection;
  final file = input.files?.firstOrNull;
  if (file == null) return null;
  return readAvatarFile(file);
}

/// Reads browser file bytes directly, without a data-URL/base64 round trip.
Future<AxAvatarFile> readAvatarFile(html.File file) async {
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
    if (result is Uint8List || result is ByteBuffer) {
      completer.complete(AxAvatarFile(
        bytes:
            result is Uint8List ? result : (result as ByteBuffer).asUint8List(),
        mediaType: mediaType,
      ));
      return;
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
  reader.readAsArrayBuffer(file);
  return completer.future;
}

extension on List<html.File> {
  html.File? get firstOrNull => isEmpty ? null : first;
}
