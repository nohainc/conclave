import 'local_worker_permissions.dart';

class RuntimeViolation implements Exception {
  const RuntimeViolation(this.message);
  final String message;
  @override
  String toString() => 'RuntimeViolation: $message';
}

/// Validates the immutable Space/Workspace scope before an Engine process is
/// launched. Workspace treats the snapshot as untrusted input even though
/// Cloud produced it, because local Worker execution must not widen its scope.
void validateAssignmentScope(
  Map<String, Object?> payload, {
  required Set<String> localWorkerPermissions,
}) {
  final snapshot = payload['permissionSnapshot'];
  if (snapshot is! Map) {
    throw const RuntimeViolation('assignment permission snapshot is required');
  }
  for (final field in [
    'spaceId',
    'workspaceId',
    'grantId',
    'requesterUserId'
  ]) {
    final value = snapshot[field];
    if (value is! String || value.trim().isEmpty) {
      throw RuntimeViolation('assignment snapshot field $field is required');
    }
  }
  if (snapshot['spaceId'] != payload['spaceId'] ||
      snapshot['workspaceId'] != payload['executionWorkspaceId']) {
    throw const RuntimeViolation('assignment scope identity mismatch');
  }
  final permissions = snapshot['permissions'];
  if (permissions is! List || permissions.any((value) => value is! String)) {
    throw const RuntimeViolation(
        'assignment effective permissions are invalid');
  }
  final requestedPermissions = payload['permissions'];
  if (requestedPermissions != null &&
      (requestedPermissions is! List ||
          !_sameStrings(requestedPermissions, permissions))) {
    throw const RuntimeViolation('assignment permission fields do not match');
  }
  for (final permission in permissions.cast<String>()) {
    if (!executionPermissionIds.contains(permission)) {
      throw RuntimeViolation('assignment permission is unknown: $permission');
    }
    if (_isSystemAdministration(permission)) {
      throw RuntimeViolation(
          'system administration is never available to Space assignments: $permission');
    }
    if (!runtimePermissionAllowed(permission, localWorkerPermissions)) {
      throw RuntimeViolation(
          'assignment permission is not allowed for local Worker: $permission');
    }
    if (permission == 'network:use' &&
        _networkMode(snapshot['networkPolicy']) == 'deny_all') {
      throw const RuntimeViolation(
          'network permission is denied by Workspace policy');
    }
  }
  _rejectWorkerControlledPaths(payload);
  _rejectCredentialMaterial(payload);
}

bool _sameStrings(Object? left, Object? right) {
  if (left is! List || right is! List || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _isSystemAdministration(String permission) => const {
      'system:admin',
      'system:administration',
      'workspace:admin',
      'process:admin',
    }.contains(permission);

bool runtimePermissionAllowed(
    String permission, Set<String> localWorkerPermissions) {
  return executionPermissionIds.contains(permission) &&
      localWorkerPermissions.contains(permission);
}

String _networkMode(Object? value) {
  if (value is Map && value['mode'] is String) return value['mode'] as String;
  return 'deny_all';
}

void _rejectWorkerControlledPaths(Map<String, Object?> value) {
  const forbidden = {
    'workingDirectory',
    'working_directory',
    'cwd',
    'workdir',
    'workspacePath'
  };
  void visit(Object? current) {
    if (current is Map) {
      for (final entry in current.entries) {
        if (forbidden.contains(entry.key.toString())) {
          throw const RuntimeViolation(
              'Worker cannot choose an alternate working directory');
        }
        visit(entry.value);
      }
    } else if (current is List) {
      for (final item in current) {
        visit(item);
      }
    }
  }

  visit(value);
}

/// Rejects Cloud/Worker payloads that attempt to choose a process CWD.
///
/// The Workspace must resolve the Thread directory locally from immutable IDs.
void rejectWorkerControlledPaths(Map<String, Object?> value) {
  _rejectWorkerControlledPaths(value);
}

void _rejectCredentialMaterial(Map<String, Object?> value) {
  const forbidden = {
    'secret',
    'secrets',
    'token',
    'password',
    'apiKey',
    'privateKey'
  };
  void visit(Object? current) {
    if (current is Map) {
      for (final entry in current.entries) {
        final key = entry.key.toString().replaceAll('_', '').toLowerCase();
        if (forbidden.any((part) => key == part.toLowerCase())) {
          throw const RuntimeViolation(
              'Assignment payload contains credential material');
        }
        visit(entry.value);
      }
    } else if (current is List) {
      for (final item in current) {
        visit(item);
      }
    }
  }

  visit(value);
}
