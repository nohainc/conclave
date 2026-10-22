class AxAvatarFile {
  const AxAvatarFile(
      {required this.bytes,
      required this.mediaType,
      required this.thumbnailBytes});

  final List<int> bytes;
  final String mediaType;
  final List<int> thumbnailBytes;
}

Future<AxAvatarFile?> pickAvatarFile() =>
    throw UnsupportedError('Avatar uploads are available in the web app.');
