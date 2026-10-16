import 'dart:convert';
import 'dart:io';

import 'repository_root.dart';

File get fixtureCliProfileFile => File(
      '$repositoryRoot/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
    );

Map<String, Object?> buildTestWorkerProfile({
  String? profileDefinitionId,
  String? logicalWorkerTypeId,
  int? releaseVersion,
  Map<String, Object?>? engineCompatibility,
  String? providerToolName,
  List<String>? executableCandidates,
  List<Map<String, Object?>>? supportedVersions,
  Map<String, Object?>? providerTool,
  Map<String, Object?>? environment,
  Map<String, Object?>? probe,
  Map<String, Object?>? execution,
  Map<String, Object?>? session,
  Map<String, Object?>? model,
  Map<String, Object?>? timeout,
  Map<String, Object?>? sandbox,
  List<Object?>? progress,
  Map<String, Object?>? errors,
  List<Object?>? compatibilityOverrides,
}) {
  final profile = jsonDecode(fixtureCliProfileFile.readAsStringSync())
      as Map<String, Object?>;
  if (profileDefinitionId != null) {
    profile['profileDefinitionId'] = profileDefinitionId;
  }
  if (logicalWorkerTypeId != null) {
    profile['logicalWorkerTypeId'] = logicalWorkerTypeId;
  }
  if (releaseVersion != null) {
    profile['releaseVersion'] = releaseVersion;
  }
  if (engineCompatibility != null) {
    profile['engineCompatibility'] = engineCompatibility;
  }
  if (providerTool != null) {
    profile['providerTool'] = providerTool;
  } else {
    final tool = Map<String, Object?>.from(profile['providerTool']! as Map);
    if (providerToolName != null) tool['name'] = providerToolName;
    if (executableCandidates != null) {
      tool['executableCandidates'] = executableCandidates;
    }
    if (supportedVersions != null) {
      tool['supportedVersions'] = supportedVersions;
    }
    profile['providerTool'] = tool;
  }
  if (environment != null) profile['environment'] = environment;
  if (probe != null) profile['probe'] = probe;
  if (execution != null) profile['execution'] = execution;
  if (session != null) profile['session'] = session;
  if (model != null) profile['model'] = model;
  if (timeout != null) profile['timeout'] = timeout;
  if (sandbox != null) profile['sandbox'] = sandbox;
  if (progress != null) profile['progress'] = progress;
  if (errors != null) profile['errors'] = errors;
  if (compatibilityOverrides != null) {
    profile['compatibilityOverrides'] = compatibilityOverrides;
  }
  return profile;
}
