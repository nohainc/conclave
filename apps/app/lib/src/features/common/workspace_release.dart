/// Latest static Workspace release until release metadata is served by Cloud.
const conclaveWorkspaceLatestVersion = '1.0.3';

bool workspaceUpdateAvailable(String installedVersion) {
  final installed = _versionParts(installedVersion);
  final latest = _versionParts(conclaveWorkspaceLatestVersion);
  if (installed == null || latest == null) return false;
  for (var index = 0; index < latest.length; index++) {
    final installedPart = index < installed.length ? installed[index] : 0;
    if (installedPart != latest[index]) return installedPart < latest[index];
  }
  return false;
}

List<int>? _versionParts(String value) {
  final match =
      RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?(?:[-+].*)?$').firstMatch(value.trim());
  if (match == null) return null;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.tryParse(match.group(3) ?? '0') ?? 0,
  ];
}
