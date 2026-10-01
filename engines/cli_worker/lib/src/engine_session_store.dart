import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Local logical-session mapping. Provider session IDs never cross Protocol 4.0.
class EngineSessionStore {
  const EngineSessionStore(this.directory);

  final Directory directory;

  Future<String?> read({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
    required List<String> compatibleFormatIds,
  }) async {
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    if (!await file.exists()) return null;
    await _assertContained(file);
    if (await file.length() > 2048) {
      throw const FormatException('Engine session state exceeds its limit');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['sessionKey'] != sessionKey ||
        decoded['workerTypeId'] != workerTypeId ||
        decoded['profileDefinitionId'] != profileDefinitionId ||
        decoded['providerToolIdentity'] != providerToolIdentity ||
        decoded['profileReleaseVersion'] is! int ||
        decoded['profileReleaseVersion'] < 1 ||
        decoded['sessionFormatId'] is! String ||
        !_validFormatId(decoded['sessionFormatId'] as String) ||
        decoded['sessionId'] is! String ||
        !_validSessionId(decoded['sessionId'] as String)) {
      throw const FormatException('Engine session state is invalid');
    }
    final storedFormat = decoded['sessionFormatId'] as String;
    if (!compatibleFormatIds.contains(storedFormat)) return null;
    return decoded['sessionId'] as String;
  }

  Future<void> write({
    required String sessionKey,
    required String workerTypeId,
    required String profileDefinitionId,
    required String providerToolIdentity,
    required int profileReleaseVersion,
    required String sessionFormatId,
    required String sessionId,
  }) async {
    if (!_validSessionId(sessionId) ||
        !_validFormatId(sessionFormatId) ||
        profileReleaseVersion < 1) {
      throw const FormatException('provider session identity is out of bounds');
    }
    await directory.create(recursive: true);
    final file = _file(
      sessionKey,
      workerTypeId,
      profileDefinitionId,
      providerToolIdentity,
    );
    await _assertContained(file, allowMissing: true);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'sessionKey': sessionKey,
        'workerTypeId': workerTypeId,
        'profileDefinitionId': profileDefinitionId,
        'providerToolIdentity': providerToolIdentity,
        'profileReleaseVersion': profileReleaseVersion,
        'sessionFormatId': sessionFormatId,
        'sessionId': sessionId,
      }),
    );
  }

  Future<void> _assertContained(File file, {bool allowMissing = false}) async {
    final root = await directory.resolveSymbolicLinks();
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException(
        'Engine session state cannot be a symbolic link',
      );
    }
    if (allowMissing && !await file.exists()) return;
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}')) {
      throw const FormatException('Engine session state escaped its directory');
    }
  }

  File _file(
    String sessionKey,
    String workerTypeId,
    String profileDefinitionId,
    String providerToolIdentity,
  ) {
    if (sessionKey.isEmpty ||
        sessionKey.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionKey) ||
        !_validIdentity(workerTypeId) ||
        !_validIdentity(profileDefinitionId) ||
        providerToolIdentity.isEmpty ||
        providerToolIdentity.length > 128) {
      throw const FormatException('session scope has an invalid format');
    }
    final scopeDigest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              workerTypeId,
              profileDefinitionId,
              providerToolIdentity,
              sessionKey,
            ]),
          ),
        )
        .toString();
    return File(
      '${directory.path}${Platform.pathSeparator}session-$scopeDigest.json',
    );
  }
}

bool _validIdentity(String value) =>
    value.length <= 96 &&
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value);

bool _validFormatId(String value) =>
    value.length <= 96 &&
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(value);

bool _validSessionId(String value) =>
    value.length <= 256 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
