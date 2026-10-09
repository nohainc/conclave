class AxAvatarFile {
  const AxAvatarFile({required this.bytes, required this.mediaType});

  final List<int> bytes;
  final String mediaType;
}

Future<AxAvatarFile?> pickAvatarFile() =>
    throw UnsupportedError('Avatar uploads are available in the web app.');
