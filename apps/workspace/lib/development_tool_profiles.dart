import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter/foundation.dart';

/// Explicit local-only draft execution. It never creates a signed admission.
class DevelopmentToolProfiles {
  DevelopmentToolProfiles({
    required this.draftsRoot,
    required this.snapshotsRoot,
    required Uri cloudUri,
    bool releaseBuild = kReleaseMode,
  }) {
    if (kReleaseMode ||
        releaseBuild ||
        !const {'http', 'https'}.contains(cloudUri.scheme) ||
        !const {'localhost', '127.0.0.1', '::1'}.contains(cloudUri.host) ||
        cloudUri.userInfo.isNotEmpty) {
      throw StateError(
          'Unsigned development Profiles require a non-release Workspace and loopback Cloud.');
    }
    if (!draftsRoot.isAbsolute || !snapshotsRoot.isAbsolute) {
      throw ArgumentError('Development Profile directories must be absolute.');
    }
  }

  final Directory draftsRoot;
  final Directory snapshotsRoot;

  Future<LocalDraftProfileCandidate?> load(
      String definitionId, String workerTypeId) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$').hasMatch(definitionId)) {
      throw const FormatException('Invalid development Profile definition ID');
    }
    final source = File('${draftsRoot.path}/$definitionId/draft.json');
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    if (type != FileSystemEntityType.file ||
        await source.length() > 384 * 1024) {
      throw const FormatException('Invalid development Profile file');
    }
    final profile = LocalDraftProfileCandidate.fromProfileMap(
      Map<String, Object?>.from(jsonDecode(await source.readAsString()) as Map),
    );
    if (profile.profileDefinitionId != definitionId ||
        profile.logicalWorkerTypeId != workerTypeId) {
      throw const FormatException(
          'Development Profile identity does not match Cloud catalog');
    }
    return profile;
  }

  /// Pins the schema-validated payload by digest so edits cannot change a run.
  Future<File> snapshot(ToolProfileCandidate candidate) async {
    if (candidate.isSigned) {
      throw ArgumentError('Expected an unsigned candidate');
    }
    await snapshotsRoot.create(recursive: true);
    final file = File('${snapshotsRoot.path}/${candidate.payloadDigest}.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Development snapshot cannot be a symlink');
    }
    final content = canonicalJson(candidate.profile);
    if (!await file.exists()) {
      await file.writeAsString(content, flush: true);
    } else if (await file.readAsString() != content) {
      throw const FormatException('Development snapshot digest mismatch');
    }
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['700', snapshotsRoot.path]);
      await Process.run('chmod', ['600', file.path]);
    }
    return file;
  }
}
