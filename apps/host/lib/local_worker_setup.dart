import 'package:flutter/material.dart';
import 'dart:async';

import 'adapter_prerequisite.dart';
import 'copyable_messages.dart';
import 'configured_worker_registry.dart';

class LocalWorkerTypeOption {
  const LocalWorkerTypeOption({
    required this.id,
    required this.adapterId,
    required this.name,
    required this.description,
    required this.authStrategy,
    required this.authLabel,
    required this.prerequisite,
    this.executablePrerequisite,
    this.additionalPrerequisites = const [],
    required this.permissions,
  });

  final String id;
  final String adapterId;
  final String name;
  final String description;
  final String authStrategy;
  final String authLabel;
  final String prerequisite;
  final AdapterExecutablePrerequisite? executablePrerequisite;
  final List<AdapterExecutablePrerequisite> additionalPrerequisites;
  final List<String> permissions;

  static const supported = <LocalWorkerTypeOption>[
    LocalWorkerTypeOption(
      id: 'chatgpt',
      adapterId: 'codex',
      name: 'ChatGPT',
      description: 'Use ChatGPT through the Codex CLI on this computer.',
      authStrategy: 'browser_auth',
      authLabel: 'Codex CLI',
      prerequisite: 'Codex CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'codex', minimumVersion: '0.158.0'),
      additionalPrerequisites: [
        AdapterExecutablePrerequisite(executable: 'node'),
      ],
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
    LocalWorkerTypeOption(
      id: 'gemini',
      adapterId: 'antigravity',
      name: 'Gemini',
      description: 'Use Gemini through the Antigravity CLI on this computer.',
      authStrategy: 'browser_auth',
      authLabel: 'Antigravity CLI',
      prerequisite: 'Antigravity CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
        executable: 'agy',
        minimumVersion: '1.1.8',
        maximumVersion: '1.2.11',
      ),
      additionalPrerequisites: [
        AdapterExecutablePrerequisite(executable: 'node'),
      ],
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
  ];
}

/// Persists local Worker configuration without accepting provider credentials.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({
    required this.registry,
    this.requireStepUp,
  });

  final LocalConfiguredWorkerRegistry registry;
  final Future<bool> Function(String reason)? requireStepUp;

  bool _isSupported(LocalWorkerTypeOption type) =>
      LocalWorkerTypeOption.supported.any((option) => option.id == type.id);

  Future<LocalConfiguredWorker> create({
    required LocalWorkerTypeOption type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    final permissionsReady = type.permissions.every(permissions.contains);
    final isReady = authenticationReady &&
        adapterReady &&
        prerequisiteReady &&
        permissionsReady;
    return registry.create(
      name: type.name,
      workerTypeId: type.id,
      authStrategy: type.authStrategy,
      defaultModel: null,
      adapterConfig: const {},
      allowedModels: const [],
      localPermissions: permissions,
      status:
          isReady ? LocalWorkerStatus.ready : LocalWorkerStatus.needsAttention,
      credentialStatus: authenticationReady
          ? LocalWorkerCredentialStatus.ready
          : LocalWorkerCredentialStatus.needsAuthentication,
    );
  }

  Future<LocalConfiguredWorker> update({
    required LocalConfiguredWorker current,
    required LocalWorkerTypeOption type,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (!_isSupported(type)) {
      throw ArgumentError('This Worker Type is not supported in v1.');
    }
    if (current.workerTypeId != type.id) {
      throw ArgumentError('Worker Type cannot be changed while editing.');
    }
    final permissionsChanged =
        permissions.length != current.localPermissions.length ||
            !permissions.toSet().containsAll(current.localPermissions);
    if (permissionsChanged) {
      final gate = requireStepUp;
      if (gate == null ||
          !await gate('Change local Worker execution permissions')) {
        throw StateError(
            'Local authentication is required to save these changes.');
      }
    }
    final authReady = authenticationReady ||
        current.credentialStatus == LocalWorkerCredentialStatus.ready;
    final permissionsReady = type.permissions.every(permissions.contains);
    final isReady =
        authReady && adapterReady && prerequisiteReady && permissionsReady;
    final status = current.status == LocalWorkerStatus.disabled
        ? LocalWorkerStatus.disabled
        : isReady
            ? LocalWorkerStatus.ready
            : LocalWorkerStatus.needsAttention;
    return registry.update(
      current.id,
      (record) => record.copyWith(
        name: type.name,
        clearModelConfiguration: true,
        localPermissions: permissions,
        credentialStatus: authReady
            ? LocalWorkerCredentialStatus.ready
            : LocalWorkerCredentialStatus.needsAuthentication,
        status: status,
      ),
    );
  }
}

/// Local-only setup for one fixed first-party CLI Worker catalog entry.
class AddLocalWorkerDialog extends StatefulWidget {
  const AddLocalWorkerDialog({
    required this.registry,
    required this.type,
    required this.adapterAvailable,
    required this.probePrerequisites,
    this.launchAuthentication,
    this.validateAuthentication,
    this.ensureAdapter,
    this.onReadinessChecked,
    this.worker,
    this.requireStepUp,
    super.key,
  });

  final LocalConfiguredWorkerRegistry registry;
  final LocalWorkerTypeOption type;
  final FutureOr<bool> Function(String workerTypeId, List<String> permissions)
      adapterAvailable;
  final Future<List<AdapterPrerequisiteResult>> Function(String workerTypeId)
      probePrerequisites;
  final Future<void> Function(String workerTypeId)? launchAuthentication;
  final Future<bool> Function(String workerTypeId)? validateAuthentication;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final Future<void> Function()? onReadinessChecked;
  final LocalConfiguredWorker? worker;
  final Future<bool> Function(String reason)? requireStepUp;

  @override
  State<AddLocalWorkerDialog> createState() => _AddLocalWorkerDialogState();
}

class _AddLocalWorkerDialogState extends State<AddLocalWorkerDialog> {
  final Set<String> _permissions = {};
  bool _saving = false;
  bool _checkingReadiness = false;
  bool? _adapterReady;
  bool? _authenticationReady;
  List<AdapterPrerequisiteResult>? _prerequisiteResults;
  String? _error;
  String? _readinessError;

  LocalWorkerTypeOption get _type => widget.type;

  @override
  void initState() {
    super.initState();
    _permissions.addAll(widget.worker?.localPermissions ?? _type.permissions);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshReadiness();
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _save() async {
    final current = widget.worker;
    final permissions = _permissions.toList()..sort();
    final permissionsChanged = current != null &&
        (permissions.length != current.localPermissions.length ||
            !permissions.toSet().containsAll(current.localPermissions));
    if (permissionsChanged) {
      final requireStepUp = widget.requireStepUp;
      if (requireStepUp == null ||
          !await requireStepUp('Change local Worker execution permissions')) {
        if (mounted) {
          setState(() => _error =
              'Local authentication is required to save these changes.');
        }
        return;
      }
      if (!mounted) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final readiness = await _probeReadiness(
        permissions,
        installAdapter: true,
      );
      if (mounted) _publishReadiness(readiness);
      final service = LocalWorkerSetupService(
        registry: widget.registry,
        requireStepUp: widget.requireStepUp,
      );
      if (current == null) {
        await service.create(
          type: _type,
          permissions: permissions,
          adapterReady: readiness.adapterReady,
          prerequisiteReady: readiness.prerequisitesReady,
          authenticationReady: readiness.authenticationReady,
        );
      } else {
        await service.update(
          current: current,
          type: _type,
          permissions: permissions,
          adapterReady: readiness.adapterReady,
          prerequisiteReady: readiness.prerequisitesReady,
          authenticationReady: readiness.authenticationReady,
        );
      }
      await widget.onReadinessChecked?.call();
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_LocalWorkerReadiness> _probeReadiness(
    List<String> permissions, {
    bool installAdapter = false,
  }) async {
    final prerequisiteResults =
        await widget.probePrerequisites(_type.adapterId);
    var adapterReady =
        await widget.adapterAvailable(_type.adapterId, permissions);
    if (!adapterReady && installAdapter && widget.ensureAdapter != null) {
      await widget.ensureAdapter!(_type.adapterId);
      adapterReady =
          await widget.adapterAvailable(_type.adapterId, permissions);
    }
    final authenticationReady =
        await widget.validateAuthentication?.call(_type.adapterId) ?? false;
    return _LocalWorkerReadiness(
      prerequisites: prerequisiteResults,
      adapterReady: adapterReady,
      authenticationReady: authenticationReady,
    );
  }

  Future<void> _refreshReadiness({bool persist = false}) async {
    if (_checkingReadiness || _saving) return;
    setState(() {
      _checkingReadiness = true;
      _readinessError = null;
    });
    try {
      final readiness = await _probeReadiness(_permissions.toList());
      if (mounted) _publishReadiness(readiness);
      if (persist) await widget.onReadinessChecked?.call();
    } catch (error) {
      if (mounted) setState(() => _readinessError = error.toString());
    } finally {
      if (mounted) setState(() => _checkingReadiness = false);
    }
  }

  void _publishReadiness(_LocalWorkerReadiness readiness) {
    setState(() {
      _prerequisiteResults = readiness.prerequisites;
      _adapterReady = readiness.adapterReady;
      _authenticationReady = readiness.authenticationReady;
      _readinessError = null;
    });
  }

  Future<void> _signIn() async {
    if (widget.worker != null) {
      final requireStepUp = widget.requireStepUp;
      if (requireStepUp == null ||
          !await requireStepUp('Replace Worker sign-in credentials')) {
        if (mounted) {
          setState(() => _error =
              'Local authentication is required to replace Worker sign-in credentials.');
        }
        return;
      }
    }
    try {
      await widget.launchAuthentication!(_type.adapterId);
      if (mounted) {
        setState(() => _error = _type.id == 'chatgpt'
            ? 'Codex login opened. Complete sign-in in Codex, then select Check again.'
            : 'Antigravity opened. Complete sign-in there, then select Check again.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not start sign-in: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.worker == null
          ? 'Set up ${_type.name}'
          : 'Configure ${_type.name}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_type.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 16),
              Text('Readiness',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              if (_prerequisiteResults case final results?)
                for (var i = 0; i < results.length; i++)
                  _ReadinessRow(
                    label: _prerequisiteLabel(i),
                    result: results[i],
                  )
              else
                const _ReadinessRow(
                  label: 'CLI and execution prerequisites',
                  value: 'Not checked',
                ),
              _ReadinessRow(
                label: _type.id == 'chatgpt'
                    ? 'Codex authentication'
                    : 'Antigravity authentication',
                value: _authenticationReady == null
                    ? 'Not checked'
                    : _authenticationReady!
                        ? 'Ready'
                        : 'Login required',
              ),
              _ReadinessRow(
                label: 'Verified adapter',
                value: _adapterReady == null
                    ? 'Not checked'
                    : _adapterReady!
                        ? 'Ready'
                        : 'Not installed or unverified',
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _checkingReadiness || _saving
                      ? null
                      : () => _refreshReadiness(persist: true),
                  icon: _checkingReadiness
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: Text(_checkingReadiness ? 'Checking…' : 'Check again'),
                ),
              ),
              if (_readinessError != null)
                CopyableMessageText(
                  'Readiness check failed: $_readinessError',
                  style: TextStyle(color: theme.colorScheme.error),
                  iconColor: theme.colorScheme.error,
                ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_circle_outlined, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_type.authLabel,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            'Authentication and billing are managed in the local CLI.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.launchAuthentication != null)
                      FilledButton.tonalIcon(
                        onPressed:
                            _saving || _checkingReadiness ? null : _signIn,
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: Text(_type.id == 'chatgpt'
                            ? 'Open Codex Login'
                            : 'Open Antigravity'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Local Permissions',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final permission in _type.permissions)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(_permissionLabel(permission),
                      style: const TextStyle(fontSize: 14)),
                  value: _permissions.contains(permission),
                  onChanged: _saving
                      ? null
                      : (allowed) => setState(() {
                            if (allowed == true) {
                              _permissions.add(permission);
                            } else {
                              _permissions.remove(permission);
                            }
                          }),
                ),
              const SizedBox(height: 8),
              Text(
                'Required tool: ${_type.prerequisite}. This Worker becomes Ready once its adapter, CLI, authentication, and permissions are verified.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_error != null)
                CopyableMessageText(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  iconColor: theme.colorScheme.error,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _checkingReadiness
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _checkingReadiness ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }

  String _prerequisiteLabel(int index) {
    final checks = [
      if (_type.executablePrerequisite case final primary?) primary,
      ..._type.additionalPrerequisites,
    ];
    if (index >= checks.length) return 'Execution prerequisite';
    final executable = checks[index].executable;
    return executable == 'codex'
        ? 'Codex CLI'
        : executable == 'agy'
            ? 'Antigravity CLI'
            : executable == 'node'
                ? 'Node.js'
                : executable;
  }

  String _permissionLabel(String permission) => switch (permission) {
        'workstream_filesystem' => 'Read and modify Workstream files',
        'shell_execution' => 'Run local shell commands and tools',
        _ => permission,
      };
}

class _LocalWorkerReadiness {
  const _LocalWorkerReadiness({
    required this.prerequisites,
    required this.adapterReady,
    required this.authenticationReady,
  });

  final List<AdapterPrerequisiteResult> prerequisites;
  final bool adapterReady;
  final bool authenticationReady;

  bool get prerequisitesReady =>
      prerequisites.isNotEmpty && prerequisites.every((item) => item.satisfied);
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow({required this.label, this.result, this.value});

  final String label;
  final AdapterPrerequisiteResult? result;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = result == null
        ? value ?? 'Not checked'
        : result!.satisfied
            ? 'Ready${result!.detectedVersion == null ? '' : ' · ${result!.detectedVersion}'}'
            : result!.message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 164,
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: result != null && !result!.satisfied
                ? CopyableMessageText(
                    status,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                    iconColor: theme.colorScheme.error,
                  )
                : Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
