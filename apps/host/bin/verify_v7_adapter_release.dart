import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/release_trust_roots.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
        'Usage: dart run bin/verify_v7_adapter_release.dart <archive> <manifest>');
    exitCode = 2;
    return;
  }
  final archive = await File(args[0]).readAsBytes();
  final manifest = jsonDecode(await File(args[1]).readAsString());
  if (manifest is! Map) {
    throw const FormatException('manifest must be an object');
  }
  final workerTypeId = manifest['workerTypeId'];
  if (workerTypeId is! String) {
    throw const FormatException('workerTypeId missing');
  }
  final root =
      await Directory.systemTemp.createTemp('conclave-release-admission-');
  try {
    final store = V7AdapterPackageStore(
      root: Directory('${root.path}/packages'),
      trustPolicy: workspaceReleaseTrustPolicy(),
      allowedPermissions: WorkerPermission.values.toSet(),
    );
    await store.installArchive(
      archiveBytes: archive,
      expectedManifest: Map<String, Object?>.from(manifest),
    );
    stdout.writeln('verified $workerTypeId ${manifest['adapterVersion']}');
  } finally {
    await root.delete(recursive: true);
  }
}
