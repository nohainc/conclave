part of '../ax_data.dart';

mixin _NotesApi on _AxApiClientCore implements AxNotesDataSource {
  AxNote _noteFrom(http.Response response, String action) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('$action failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final note = body is Map ? body['note'] : null;
    if (note is! Map) throw AxApiException('$action response is malformed');
    return AxNote.fromJson(Map<String, dynamic>.from(note));
  }

  @override
  Future<List<AxNote>> loadNotes() async {
    final body = await _getJson(Uri.parse('$baseUrl/notes'));
    return (body['notes'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxNote.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxNote> loadNote(String id) async {
    final body =
        await _getJson(Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'));
    final note = body['note'];
    if (note is! Map) throw const AxApiException('Note response is malformed');
    return AxNote.fromJson(Map<String, dynamic>.from(note));
  }

  @override
  Future<AxNote> createNote({String title = '', String body = ''}) async =>
      _noteFrom(
          await client.post(Uri.parse('$baseUrl/notes'),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode({'title': title, 'body': body})),
          'Creating the note');

  @override
  Future<AxNote> updateNote(String id,
          {String? title, String? body, required int revision}) async =>
      _noteFrom(
          await client.put(
              Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode({
                if (title != null) 'title': title,
                if (body != null) 'body': body,
                'revision': revision,
              })),
          'Saving the note');

  @override
  Future<void> deleteNote(String id) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/notes/${Uri.encodeComponent(id)}'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Deleting the note failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<AxNote?> loadThreadNote(String threadId) async {
    final body = await _getJson(
        Uri.parse('$baseUrl/threads/${Uri.encodeComponent(threadId)}/note'));
    final note = body['note'];
    return note is Map
        ? AxNote.fromJson(Map<String, dynamic>.from(note))
        : null;
  }

  @override
  Future<AxNote> saveThreadNote(String threadId,
          {required String body, int? revision}) async =>
      _noteFrom(
          await client.put(
              Uri.parse(
                  '$baseUrl/threads/${Uri.encodeComponent(threadId)}/note'),
              headers: _headers(contentType: 'application/json'),
              body: jsonEncode(
                  {'body': body, if (revision != null) 'revision': revision})),
          'Saving the note');
}
