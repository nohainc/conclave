import 'dart:convert';

import 'package:flutter/services.dart';

import 'bundled_adapter_package.dart';
import 'first_party_worker_registry.dart';

/// Loads a package generated and verified as part of the Workspace build.
Future<BundledAdapterPackage?> loadBundledFirstPartyAdapter(
  String workerTypeId, {
  AssetBundle? bundle,
}) async {
  final descriptor = FirstPartyWorkerPackage.forProductOrPackageId(
    workerTypeId,
  );
  if (descriptor == null) return null;
  final adapterPackageId = descriptor.packageId;
  final assets = bundle ?? rootBundle;
  try {
    final archive = await assets.load('assets/adapters/$adapterPackageId.tgz');
    final manifestData =
        await assets.loadString('assets/adapters/$adapterPackageId.json');
    final decoded = jsonDecode(manifestData);
    if (decoded is! Map || decoded['workerTypeId'] != adapterPackageId) {
      return null;
    }
    return BundledAdapterPackage(
      archiveBytes: archive.buffer.asUint8List(
        archive.offsetInBytes,
        archive.lengthInBytes,
      ),
      manifest: Map<String, Object?>.from(decoded),
    );
  } on Object {
    return null;
  }
}
