import 'adapter_prerequisite.dart';
import 'first_party_worker_adapter_descriptor.dart';
import 'first_party_worker_cli_locator.dart';

class FirstPartyWorkerCliProbeResult {
  const FirstPartyWorkerCliProbeResult({
    required this.executable,
    required this.versionProbe,
    this.executablePath,
  });

  final String executable;
  final String? executablePath;
  final AdapterPrerequisiteResult versionProbe;
}

/// Resolves and version-checks a descriptor's executable. Authentication and
/// effective readiness are checked through the admitted Local Adapter Protocol
/// process, not by Workspace launching provider-specific CLI commands.
class FirstPartyWorkerAdapterProbe {
  const FirstPartyWorkerAdapterProbe({
    this.locator = const FirstPartyWorkerCliExecutableLocator(),
  });

  final FirstPartyWorkerCliExecutableLocator locator;

  Future<FirstPartyWorkerCliProbeResult> probe(
    FirstPartyWorkerAdapterDescriptor descriptor, {
    String? cachedExecutablePath,
  }) async {
    final found = await locator.locate(
      descriptor,
      cachedPath: cachedExecutablePath,
    );
    return FirstPartyWorkerCliProbeResult(
      executable: descriptor.executableCandidates.first,
      executablePath: found?.path,
      versionProbe: found?.versionProbe ??
          AdapterPrerequisiteResult(
            satisfied: false,
            message: 'Required executable is not available: '
                '${descriptor.executableCandidates.join(' or ')}',
          ),
    );
  }
}
