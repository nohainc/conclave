Future<({List<Map<String, dynamic>> files, String? notice})>
    pickWorkRequestFiles({int existing = 0}) async => throw UnsupportedError(
        'File attachments are available in the web app.');

void saveThreadFile(List<int> bytes, String name) =>
    throw UnsupportedError('File downloads are available in the web app.');

void openThreadFile(List<int> bytes, String name, String mediaType) =>
    throw UnsupportedError('Opening files is available in the web app.');
