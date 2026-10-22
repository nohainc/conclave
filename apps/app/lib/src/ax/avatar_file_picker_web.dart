// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

class AxAvatarFile {
  const AxAvatarFile(
      {required this.bytes,
      required this.mediaType,
      required this.thumbnailBytes});

  final List<int> bytes;
  final String mediaType;
  final List<int> thumbnailBytes;
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
  final objectUrl = html.Url.createObjectUrl(file);
  late List<int> thumbnail;
  try {
    final image = html.ImageElement(src: objectUrl);
    final loaded = Completer<void>();
    image.onLoad.first.then((_) {
      if (!loaded.isCompleted) loaded.complete();
    });
    image.onError.first.then((_) {
      if (!loaded.isCompleted) {
        loaded.completeError(StateError('Could not decode the avatar image.'));
      }
    });
    if (image.complete == true && image.naturalWidth > 0) loaded.complete();
    await loaded.future;
    final scale = 128 /
        (image.naturalWidth > image.naturalHeight
            ? image.naturalWidth
            : image.naturalHeight);
    final factor = scale < 1 ? scale : 1.0;
    final canvas = html.CanvasElement(
        width: (image.naturalWidth * factor).round().clamp(1, 128),
        height: (image.naturalHeight * factor).round().clamp(1, 128));
    canvas.context2D
        .drawImageScaled(image, 0, 0, canvas.width!, canvas.height!);
    final blob = await canvas.toBlob('image/png');
    final thumbnailReader = html.FileReader()..readAsArrayBuffer(blob);
    await thumbnailReader.onLoad.first;
    final result = thumbnailReader.result;
    thumbnail =
        result is Uint8List ? result : (result as ByteBuffer).asUint8List();
  } finally {
    html.Url.revokeObjectUrl(objectUrl);
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
        thumbnailBytes: thumbnail,
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
