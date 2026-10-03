import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_paths.dart';
import '../theme/profile_lab_theme.dart';

class DiagnosticsView extends StatelessWidget {
  const DiagnosticsView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          // Section: Bundled Engine
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'BUNDLED GENERIC CLI WORKER ENGINE',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF94A3B8)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.engineExecutable != null
                              ? ProfileLabTheme.passColor.withValues(alpha: 0.2)
                              : ProfileLabTheme.failColor
                                  .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          c.engineExecutable != null ? 'AVAILABLE' : 'MISSING',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: c.engineExecutable != null
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.failColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Engine Version: $cliWorkerEngineVersion',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Materialized Path: ${c.engineExecutable?.path ?? "None"}',
                    style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Section: Provider executables declared by loaded Workers/Profiles
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'LOCAL PROVIDER CLI DISCOVERY (MACOS HOST)',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF94A3B8)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        tooltip: 'Rescan PATH',
                        onPressed: c.discoverInstalledProviders,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (c.configuredProviderExecutables.isEmpty)
                    const Text(
                      'No provider executable is declared by the loaded Worker or Profile data.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF94A3B8),
                      ),
                    )
                  else
                    for (final executable
                        in c.configuredProviderExecutables) ...[
                      if (executable != c.configuredProviderExecutables.first)
                        const Divider(color: Color(0xFF334155)),
                      _ProviderRow(
                        name: executable,
                        path: c.detectedProviderPaths[executable],
                      ),
                    ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Section: Segregated Filesystem Paths
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PROFILE LAB ISOLATED DIRECTORIES',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 12),
                  _PathRow(
                      label: 'App Support',
                      path: c.paths.applicationSupportDirectory.path),
                  const SizedBox(height: 6),
                  _PathRow(
                      label: 'Drafts Root', path: c.paths.draftsDirectory.path),
                  const SizedBox(height: 6),
                  _PathRow(
                      label: 'Engine Binaries',
                      path: c.paths.enginesDirectory.path),
                  const SizedBox(height: 6),
                  _PathRow(
                      label: 'Test Sandbox',
                      path: c.paths.sandboxDirectory.path),
                  const SizedBox(height: 6),
                  _PathRow(label: 'Logs', path: c.paths.logsDirectory.path),
                  const SizedBox(height: 6),
                  _PathRow(
                      label: 'Bundle ID / Keychain',
                      path: ProfileLabPaths.bundleIdentifier),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.name, required this.path});

  final String name;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final found = path != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            found ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 16,
            color: found ? ProfileLabTheme.passColor : const Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Provider executable: $name',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                Text(
                  path ??
                      'Not found in PATH or standard macOS developer directories',
                  style: TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    color: found
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 12,
                color: Color(0xFF94A3B8)),
          ),
        ),
        Expanded(
          child: Text(
            path,
            style: const TextStyle(
                fontFamily: 'Menlo', fontSize: 11, color: Colors.white70),
          ),
        ),
      ],
    );
  }
}
