/// A private note. Notes belong to the signed-in user, not to a Space or
/// Thread: a note linked to a Thread stays when that Thread is deleted or the
/// user leaves its Space, and is then [linked] == false with the saved
/// [spaceName] and [threadName].
class AxNote {
  const AxNote({
    required this.id,
    required this.title,
    required this.body,
    required this.revision,
    required this.updatedAt,
    this.threadId,
    this.spaceId,
    this.threadName,
    this.spaceName,
    this.linked = false,
  });

  factory AxNote.fromJson(Map<String, dynamic> json) => AxNote(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        body: json['body']?.toString() ?? '',
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        updatedAt: json['updatedAt']?.toString() ?? '',
        threadId: json['threadId']?.toString(),
        spaceId: json['spaceId']?.toString(),
        threadName: json['threadName']?.toString(),
        spaceName: json['spaceName']?.toString(),
        linked: json['linked'] == true,
      );

  final String id;
  final String title;
  final String body;
  final int revision;
  final String updatedAt;
  final String? threadId;
  final String? spaceId;
  final String? threadName;
  final String? spaceName;

  /// Where a Thread note comes from: `Thread < Space`, or null for a
  /// standalone note.
  String? get path {
    if (threadId == null) return null;
    return [threadName, spaceName]
        .map((name) => name?.trim() ?? '')
        .where((name) => name.isNotEmpty)
        .join(' < ');
  }

  /// The same path from the top down, `Space > Thread`, for the note's own
  /// page.
  String? get spacePath {
    if (threadId == null) return null;
    return [spaceName, threadName]
        .map((name) => name?.trim() ?? '')
        .where((name) => name.isNotEmpty)
        .join(' > ');
  }

  final bool linked;

  /// Title shown in lists: the note title, else its Thread, else the first
  /// line of text.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    if (threadName != null && threadName!.trim().isNotEmpty) {
      return threadName!.trim();
    }
    final firstLine = body.trim().split('\n').first.trim();
    return firstLine.isEmpty ? 'Untitled note' : firstLine;
  }
}

/// Optional capability: the signed-in user's private notes.
abstract interface class AxNotesDataSource {
  Future<List<AxNote>> loadNotes();

  Future<AxNote> loadNote(String id);

  Future<AxNote> createNote({String title = '', String body = ''});

  /// Saves only when [revision] is current; a stale save throws an
  /// `AxApiException` with status 409.
  Future<AxNote> updateNote(String id,
      {String? title, String? body, required int revision});

  Future<void> deleteNote(String id);

  /// The caller's note for [threadId], or null before the first save.
  Future<AxNote?> loadThreadNote(String threadId);

  /// Creates the Thread note when [revision] is null, otherwise updates it.
  Future<AxNote> saveThreadNote(String threadId,
      {required String body, int? revision});
}
