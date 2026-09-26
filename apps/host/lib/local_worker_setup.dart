import 'package:flutter/material.dart';
import 'dart:async';

import 'adapter_prerequisite.dart';
import 'configured_worker_registry.dart';
import 'secure_credentials.dart';

class LocalWorkerTypeOption {
  const LocalWorkerTypeOption({
    required this.id,
    required this.name,
    required this.description,
    required this.authStrategy,
    required this.authLabel,
    required this.prerequisite,
    this.executablePrerequisite,
    this.additionalPrerequisites = const [],
    required this.permissions,
    this.requiresApiKey = false,
  });

  final String id;
  final String name;
  final String description;
  final String authStrategy;
  final String authLabel;
  final String prerequisite;
  final AdapterExecutablePrerequisite? executablePrerequisite;
  final List<AdapterExecutablePrerequisite> additionalPrerequisites;
  final List<String> permissions;
  final bool requiresApiKey;

  static const supported = <LocalWorkerTypeOption>[
    LocalWorkerTypeOption(
      id: 'codex',
      name: 'Codex',
      description: 'Use a local Codex installation and account.',
      authStrategy: 'browser_auth',
      authLabel: 'ChatGPT account',
      prerequisite: 'Codex CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'codex', minimumVersion: '0.158.0'),
      additionalPrerequisites: [
        AdapterExecutablePrerequisite(executable: 'node'),
      ],
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
    LocalWorkerTypeOption(
      id: 'antigravity',
      name: 'Antigravity',
      description: 'Use Antigravity on this machine.',
      authStrategy: 'browser_auth',
      authLabel: 'Google account',
      prerequisite: 'Antigravity CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'agy', minimumVersion: '1.0.0'),
      additionalPrerequisites: [
        AdapterExecutablePrerequisite(executable: 'node'),
      ],
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
    LocalWorkerTypeOption(
      id: 'claude-code',
      name: 'Claude Code',
      description: 'Use a local Claude Code installation.',
      authStrategy: 'browser_auth',
      authLabel: 'Claude account',
      prerequisite: 'Claude Code CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'claude', minimumVersion: '2.1.41'),
      additionalPrerequisites: [
        AdapterExecutablePrerequisite(
            executable: 'node', minimumVersion: '18.0.0'),
      ],
      permissions: ['workstream_filesystem', 'shell_execution'],
    ),
    LocalWorkerTypeOption(
      id: 'openai-api',
      name: 'OpenAI API',
      description: 'Connect with a locally stored API key.',
      authStrategy: 'api_key',
      authLabel: 'API key',
      prerequisite: 'OpenAI adapter',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'node', minimumVersion: '18.0.0'),
      permissions: ['network_openai'],
      requiresApiKey: true,
    ),
    LocalWorkerTypeOption(
      id: 'gemini-api',
      name: 'Gemini API',
      description: 'Connect with a locally stored API key.',
      authStrategy: 'api_key',
      authLabel: 'API key',
      prerequisite: 'Gemini adapter',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'node', minimumVersion: '18.0.0'),
      permissions: ['network_google'],
      requiresApiKey: true,
    ),
    LocalWorkerTypeOption(
      id: 'anthropic-api',
      name: 'Anthropic API',
      description: 'Connect with a locally stored API key.',
      authStrategy: 'api_key',
      authLabel: 'API key',
      prerequisite: 'Anthropic adapter',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'node', minimumVersion: '18.0.0'),
      permissions: ['network_anthropic'],
      requiresApiKey: true,
    ),
    LocalWorkerTypeOption(
      id: 'ollama',
      name: 'Ollama',
      description: 'Use a local Ollama installation.',
      authStrategy: 'local_endpoint',
      authLabel: 'Local service',
      prerequisite: 'Ollama CLI',
      executablePrerequisite: AdapterExecutablePrerequisite(
          executable: 'node', minimumVersion: '18.0.0'),
      permissions: ['network'],
    ),
  ];
}

/// Persists local Worker configuration and directs credentials only to the
/// secure credential store. Keeping this out of the widget makes the setup
/// lifecycle independently testable.
class LocalWorkerSetupService {
  const LocalWorkerSetupService({
    required this.registry,
    required this.credentialStore,
  });

  final LocalConfiguredWorkerRegistry registry;
  final SecureCredentialStore credentialStore;

  Future<LocalConfiguredWorker> create({
    required LocalWorkerTypeOption type,
    required String name,
    required String apiKey,
    required String defaultModel,
    required String endpointUrl,
    required List<String> allowedModels,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Enter a Worker name.');
    if (type.requiresApiKey && apiKey.isEmpty) {
      throw ArgumentError('Enter the API key.');
    }
    final endpoint = endpointUrl.trim();
    final parsedEndpoint = endpoint.isEmpty ? null : Uri.tryParse(endpoint);
    if (endpoint.isNotEmpty &&
        (parsedEndpoint == null ||
            !const {'http', 'https'}.contains(parsedEndpoint.scheme) ||
            parsedEndpoint.host.isEmpty)) {
      throw ArgumentError('Endpoint must be a valid HTTP or HTTPS URL.');
    }
    if (type.requiresApiKey &&
        parsedEndpoint != null &&
        ((parsedEndpoint.scheme != 'https' &&
                !(parsedEndpoint.scheme == 'http' &&
                    const {'localhost', '127.0.0.1', '::1'}
                        .contains(parsedEndpoint.host))) ||
            parsedEndpoint.userInfo.isNotEmpty ||
            parsedEndpoint.hasQuery ||
            parsedEndpoint.hasFragment)) {
      throw ArgumentError(
          'API endpoints must use HTTPS and cannot contain credentials, queries, or fragments.');
    }
    if (type.authStrategy == 'local_endpoint' && parsedEndpoint == null) {
      throw ArgumentError('Enter the local service endpoint.');
    }
    if (type.requiresApiKey &&
        defaultModel.trim().isEmpty &&
        allowedModels.isEmpty) {
      throw ArgumentError(
          'Set a default model or allow at least one model for this API Worker.');
    }
    if (type.id == 'ollama' &&
        defaultModel.trim().isEmpty &&
        allowedModels.isEmpty) {
      throw ArgumentError('Select an installed Ollama model.');
    }
    final authReady = switch (type.authStrategy) {
      'api_key' => apiKey.isNotEmpty && authenticationReady,
      'local_endpoint' => parsedEndpoint != null && authenticationReady,
      'none' => true,
      'browser_auth' => authenticationReady,
      _ => false,
    };
    final permissionsReady = type.permissions.every(permissions.contains);
    final isReady =
        authReady && adapterReady && prerequisiteReady && permissionsReady;
    final worker = await registry.create(
      name: name.trim(),
      workerTypeId: type.id,
      authStrategy: type.authStrategy,
      defaultModel: defaultModel.trim().isEmpty ? null : defaultModel.trim(),
      adapterConfig: parsedEndpoint == null
          ? const {}
          : {'endpointUrl': parsedEndpoint.toString()},
      allowedModels: allowedModels,
      localPermissions: permissions,
      status:
          isReady ? LocalWorkerStatus.ready : LocalWorkerStatus.needsAttention,
      credentialStatus: type.authStrategy == 'local_endpoint'
          ? LocalWorkerCredentialStatus.notRequired
          : type.authStrategy == 'browser_auth' && authenticationReady
              ? LocalWorkerCredentialStatus.ready
              : LocalWorkerCredentialStatus.needsAuthentication,
    );
    if (!type.requiresApiKey) return worker;

    final key = 'worker-credential/${worker.id}';
    try {
      await credentialStore.write(key, apiKey);
      return await registry.update(
        worker.id,
        (current) => current.copyWith(
          credentialRef: key,
          credentialStatus: authReady
              ? LocalWorkerCredentialStatus.ready
              : LocalWorkerCredentialStatus.needsAuthentication,
          status: isReady
              ? LocalWorkerStatus.ready
              : LocalWorkerStatus.needsAttention,
        ),
      );
    } catch (_) {
      await credentialStore.delete(key);
      rethrow;
    }
  }

  Future<LocalConfiguredWorker> update({
    required LocalConfiguredWorker current,
    required LocalWorkerTypeOption type,
    required String name,
    required String apiKey,
    required String defaultModel,
    required String endpointUrl,
    required List<String> allowedModels,
    required List<String> permissions,
    required bool adapterReady,
    required bool prerequisiteReady,
    bool authenticationReady = false,
  }) async {
    if (current.workerTypeId != type.id) {
      throw ArgumentError('Worker Type cannot be changed while editing.');
    }
    if (name.trim().isEmpty) throw ArgumentError('Enter a Worker name.');
    final endpoint = endpointUrl.trim();
    final parsedEndpoint = endpoint.isEmpty ? null : Uri.tryParse(endpoint);
    if (endpoint.isNotEmpty &&
        (parsedEndpoint == null ||
            !const {'http', 'https'}.contains(parsedEndpoint.scheme) ||
            parsedEndpoint.host.isEmpty)) {
      throw ArgumentError('Endpoint must be a valid HTTP or HTTPS URL.');
    }
    if (type.requiresApiKey &&
        parsedEndpoint != null &&
        ((parsedEndpoint.scheme != 'https' &&
                !(parsedEndpoint.scheme == 'http' &&
                    const {'localhost', '127.0.0.1', '::1'}
                        .contains(parsedEndpoint.host))) ||
            parsedEndpoint.userInfo.isNotEmpty ||
            parsedEndpoint.hasQuery ||
            parsedEndpoint.hasFragment)) {
      throw ArgumentError(
          'API endpoints must use HTTPS and cannot contain credentials, queries, or fragments.');
    }
    if (type.authStrategy == 'local_endpoint' && parsedEndpoint == null) {
      throw ArgumentError('Enter the local service endpoint.');
    }
    if (type.requiresApiKey &&
        defaultModel.trim().isEmpty &&
        allowedModels.isEmpty) {
      throw ArgumentError(
          'Set a default model or allow at least one model for this API Worker.');
    }
    if (type.id == 'ollama' &&
        defaultModel.trim().isEmpty &&
        allowedModels.isEmpty) {
      throw ArgumentError('Select an installed Ollama model.');
    }
    if (type.requiresApiKey &&
        apiKey.isEmpty &&
        current.credentialRef == null) {
      throw ArgumentError('Enter the API key.');
    }
    final credentialRef = apiKey.isEmpty
        ? current.credentialRef
        : 'worker-credential/${current.id}';
    final previousSecret = apiKey.isNotEmpty && current.credentialRef != null
        ? credentialStore.readSync(current.credentialRef!)
        : null;
    late LocalConfiguredWorker updated;
    try {
      if (apiKey.isNotEmpty) {
        await credentialStore.write(credentialRef!, apiKey);
      }
      final authReady = switch (type.authStrategy) {
        'api_key' => credentialRef != null && authenticationReady,
        'local_endpoint' => parsedEndpoint != null && authenticationReady,
        'none' => true,
        'browser_auth' => authenticationReady ||
            current.credentialStatus == LocalWorkerCredentialStatus.ready,
        _ => false,
      };
      final permissionsReady = type.permissions.every(permissions.contains);
      final isReady =
          authReady && adapterReady && prerequisiteReady && permissionsReady;
      final status = current.status == LocalWorkerStatus.disabled
          ? LocalWorkerStatus.disabled
          : isReady
              ? LocalWorkerStatus.ready
              : LocalWorkerStatus.needsAttention;
      updated = await registry.update(
        current.id,
        (record) => record.copyWith(
          name: name.trim(),
          defaultModel:
              defaultModel.trim().isEmpty ? null : defaultModel.trim(),
          adapterConfig: parsedEndpoint == null
              ? const {}
              : {'endpointUrl': parsedEndpoint.toString()},
          allowedModels: allowedModels,
          localPermissions: permissions,
          credentialRef: credentialRef,
          credentialStatus: type.requiresApiKey
              ? authReady
                  ? LocalWorkerCredentialStatus.ready
                  : LocalWorkerCredentialStatus.needsAuthentication
              : type.authStrategy == 'local_endpoint'
                  ? LocalWorkerCredentialStatus.notRequired
                  : type.authStrategy == 'browser_auth'
                      ? authReady
                          ? LocalWorkerCredentialStatus.ready
                          : LocalWorkerCredentialStatus.needsAuthentication
                      : LocalWorkerCredentialStatus.needsAuthentication,
          status: status,
        ),
      );
    } catch (_) {
      if (apiKey.isNotEmpty) {
        if (previousSecret == null) {
          await credentialStore.delete(credentialRef!);
        } else {
          await credentialStore.write(credentialRef!, previousSecret);
        }
      }
      rethrow;
    }
    return updated;
  }
}

/// Local-only setup form. Adapter/prerequisite readiness is injected by the
/// runtime; this UI never claims a Worker is Ready while either is unavailable.
class AddLocalWorkerDialog extends StatefulWidget {
  const AddLocalWorkerDialog({
    required this.registry,
    required this.credentialStore,
    required this.adapterAvailable,
    required this.probePrerequisite,
    this.launchAuthentication,
    this.validateAuthentication,
    this.validateApiCredential,
    this.ensureAdapter,
    this.worker,
    super.key,
  });

  final LocalConfiguredWorkerRegistry registry;
  final SecureCredentialStore credentialStore;
  final FutureOr<bool> Function(String workerTypeId, List<String> permissions)
      adapterAvailable;
  final Future<AdapterPrerequisiteResult> Function(String workerTypeId)
      probePrerequisite;
  final Future<void> Function(String workerTypeId)? launchAuthentication;
  final Future<bool> Function(String workerTypeId)? validateAuthentication;
  final Future<List<String>> Function(
    String workerTypeId,
    String apiKey,
    String endpointUrl,
    List<String> localPermissions,
  )? validateApiCredential;
  final Future<bool> Function(String workerTypeId)? ensureAdapter;
  final LocalConfiguredWorker? worker;

  @override
  State<AddLocalWorkerDialog> createState() => _AddLocalWorkerDialogState();
}

class _AddLocalWorkerDialogState extends State<AddLocalWorkerDialog> {
  final _name = TextEditingController();
  final _apiKey = TextEditingController();
  final _defaultModel = TextEditingController();
  final _allowedModels = TextEditingController();
  final _endpointUrl = TextEditingController();
  late LocalWorkerTypeOption _type;
  final Set<String> _permissions = {};
  bool _saving = false;
  bool _probing = false;
  bool _replaceApiKey = false;
  String? _error;
  String? _prerequisiteMessage;
  String? _adapterMessage;
  String? _authenticationMessage;
  List<String> _discoveredModels = const [];

  @override
  void initState() {
    super.initState();
    final worker = widget.worker;
    _type = LocalWorkerTypeOption.supported.firstWhere(
      (type) => type.id == worker?.workerTypeId,
      orElse: () => LocalWorkerTypeOption.supported.first,
    );
    if (worker != null) {
      _name.text = worker.name;
      _defaultModel.text = worker.defaultModel ?? '';
      _allowedModels.text = worker.allowedModels.join(', ');
      _endpointUrl.text = worker.adapterConfig['endpointUrl'] as String? ?? '';
      _permissions.addAll(worker.localPermissions);
    } else {
      _permissions.addAll(_type.permissions);
      if (_type.id == 'ollama') {
        _endpointUrl.text = 'http://localhost:11434';
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _apiKey.dispose();
    _defaultModel.dispose();
    _allowedModels.dispose();
    _endpointUrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a Worker name.');
      return;
    }
    if (_type.requiresApiKey &&
        _apiKey.text.isEmpty &&
        (widget.worker == null || widget.worker!.credentialRef == null)) {
      setState(() =>
          _error = 'Enter the API key. It will be stored on this machine.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _authenticationMessage = null;
    });
    try {
      final allowedModels = _allowedModels.text
          .split(',')
          .map((model) => model.trim())
          .where((model) => model.isNotEmpty)
          .toSet()
          .toList();
      final service = LocalWorkerSetupService(
        registry: widget.registry,
        credentialStore: widget.credentialStore,
      );
      final permissions = _permissions.toList()..sort();
      var adapterReady =
          await widget.adapterAvailable(_type.id, _permissions.toList());
      if (!adapterReady && widget.ensureAdapter != null) {
        final installed = await widget.ensureAdapter!(_type.id);
        adapterReady =
            await widget.adapterAvailable(_type.id, _permissions.toList());
        if (!adapterReady && mounted) {
          setState(() => _adapterMessage = installed
              ? 'The installed adapter requests permissions this Worker has not been granted.'
              : 'No trusted release for this Worker Type is available from Cloud.');
        }
      } else if (!adapterReady && mounted) {
        setState(() => _adapterMessage =
            'A trusted adapter must be installed before this Worker can be Ready.');
      }
      final prerequisiteResult = await widget.probePrerequisite(_type.id);
      final prerequisiteReady = prerequisiteResult.satisfied;
      final authenticationReady = switch (_type.authStrategy) {
        'browser_auth' =>
          await widget.validateAuthentication?.call(_type.id) ?? false,
        'api_key' => adapterReady && prerequisiteReady
            ? (await _validateApiCredential(permissions)).isNotEmpty
            : false,
        'local_endpoint' => adapterReady && prerequisiteReady
            ? (await _validateApiCredential(permissions, localEndpoint: true))
                .isNotEmpty
            : false,
        _ => false,
      };
      final selectedModels = {
        if (_defaultModel.text.trim().isNotEmpty) _defaultModel.text.trim(),
        ...allowedModels,
      };
      if (selectedModels.isNotEmpty &&
          _discoveredModels.isNotEmpty &&
          selectedModels.any((model) => !_discoveredModels.contains(model))) {
        throw ArgumentError(
            'Choose a model reported by the provider or Ollama endpoint.');
      }
      if (mounted) {
        setState(() => _prerequisiteMessage = prerequisiteResult.message);
      }
      if (widget.worker == null) {
        await service.create(
          type: _type,
          name: name,
          apiKey: _apiKey.text,
          defaultModel: _defaultModel.text,
          endpointUrl: _endpointUrl.text,
          allowedModels: allowedModels,
          permissions: permissions,
          adapterReady: adapterReady,
          prerequisiteReady: prerequisiteReady,
          authenticationReady: authenticationReady,
        );
      } else {
        await service.update(
          current: widget.worker!,
          type: _type,
          name: name,
          apiKey: _apiKey.text,
          defaultModel: _defaultModel.text,
          endpointUrl: _endpointUrl.text,
          allowedModels: allowedModels,
          permissions: permissions,
          adapterReady: adapterReady,
          prerequisiteReady: prerequisiteReady,
          authenticationReady: authenticationReady,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<List<String>> _validateApiCredential(List<String> permissions,
      {bool localEndpoint = false}) async {
    final apiKey = localEndpoint
        ? ''
        : _apiKey.text.isNotEmpty
            ? _apiKey.text
            : widget.worker?.credentialRef == null
                ? ''
                : widget.credentialStore
                        .readSync(widget.worker!.credentialRef!) ??
                    '';
    if (!localEndpoint && apiKey.isEmpty) return const [];
    final validator = widget.validateApiCredential;
    if (validator == null) return const [];
    try {
      final models = await validator(
        _type.id,
        apiKey,
        _endpointUrl.text,
        permissions,
      );
      if (models.isEmpty && mounted) {
        setState(() => _authenticationMessage =
            'The API key could not be validated. Check it, then save again.');
      }
      if (mounted) setState(() => _discoveredModels = models);
      return models;
    } on Object {
      if (mounted) {
        setState(() => _authenticationMessage =
            'The API key could not be validated. Check the key and endpoint, then save again.');
      }
      return const [];
    }
  }

  Future<void> _probeModels() async {
    setState(() {
      _probing = true;
      _authenticationMessage = null;
    });
    try {
      final permissions = _permissions.toList()..sort();
      final models = await _validateApiCredential(
        permissions,
        localEndpoint: _type.authStrategy == 'local_endpoint',
      );
      if (mounted) {
        if (models.isNotEmpty) {
          setState(() {
            _discoveredModels = models;
            if (_defaultModel.text.isEmpty && models.isNotEmpty) {
              _defaultModel.text = models.first;
            }
          });
        }
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasStoredKey = widget.worker?.credentialRef != null && !_replaceApiKey;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.worker == null ? Icons.add_circle_outline : Icons.edit_note,
            size: 24,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(widget.worker == null ? 'Add Worker' : 'Edit Worker'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<LocalWorkerTypeOption>(
                key: const Key('worker-type-selector'),
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: 'Worker Type',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                items: [
                  for (final type in LocalWorkerTypeOption.supported)
                    DropdownMenuItem(
                      value: type,
                      child: Row(
                        children: [
                          Icon(_typeIcon(type.id), size: 18),
                          const SizedBox(width: 10),
                          Text(type.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    )
                ],
                onChanged: _saving || widget.worker != null
                    ? null
                    : (type) => setState(() {
                          _type = type!;
                          _endpointUrl.text = type.id == 'ollama'
                              ? 'http://localhost:11434'
                              : '';
                          _permissions.clear();
                          _permissions.addAll(type.permissions);
                          _discoveredModels = const [];
                          _error = null;
                        }),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  _type.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('worker-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Worker Name',
                  hintText: 'e.g. Personal Claude, Local Ollama',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              if (_type.requiresApiKey) ...[
                if (hasStoredKey) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: theme.colorScheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'API key stored securely',
                                style: TextStyle(fontWeight: FontWeight.w500),
                              ),
                              Text(
                                'Encrypted on this machine.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _replaceApiKey = true),
                          child: const Text('Replace key'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  TextField(
                    key: const Key('worker-api-key'),
                    controller: _apiKey,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _type.authLabel,
                      hintText: 'Enter secret API key',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      helperText:
                          'Stored in this machine’s secure credential store.',
                    ),
                  ),
                ],
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: theme.colorScheme.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _type.authStrategy == 'browser_auth'
                            ? Icons.account_circle_outlined
                            : Icons.dns_outlined,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_type.authLabel,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                              _type.authStrategy == 'browser_auth'
                                  ? 'Sign in locally on this machine.'
                                  : 'Uses a local service; no external credential required.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_type.authStrategy == 'browser_auth' &&
                          (_type.id == 'codex' ||
                              _type.id == 'antigravity' ||
                              _type.id == 'claude-code') &&
                          widget.launchAuthentication != null)
                        FilledButton.tonalIcon(
                          onPressed: _saving
                              ? null
                              : () async {
                                  try {
                                    await widget
                                        .launchAuthentication!(_type.id);
                                    if (mounted) {
                                      setState(() => _error =
                                          'Sign-in launched. Complete sign-in in browser/terminal, then save.');
                                    }
                                  } catch (error) {
                                    if (mounted) {
                                      setState(() => _error =
                                          'Could not start sign-in: $error');
                                    }
                                  }
                                },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('Sign in'),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_type.authStrategy == 'local_endpoint' ||
                  _type.id == 'ollama') ...[
                TextField(
                  key: const Key('worker-endpoint'),
                  controller: _endpointUrl,
                  decoration: InputDecoration(
                    labelText: 'Service Endpoint URL',
                    hintText: 'http://localhost:11434',
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    helperText:
                        'Local Ollama endpoint accessible on this machine.',
                  ),
                ),
              ] else ...[
                TextField(
                  key: const Key('worker-endpoint'),
                  controller: _endpointUrl,
                  decoration: const InputDecoration(
                    labelText: 'Custom Endpoint URL (optional)',
                    hintText: 'Leave empty for default provider endpoint',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    helperText: 'Optional proxy or custom API base URL.',
                  ),
                ),
              ],
              if (widget.validateApiCredential != null &&
                  (_type.requiresApiKey ||
                      _type.authStrategy == 'local_endpoint')) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving || _probing ? null : _probeModels,
                    icon: _probing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.manage_search, size: 18),
                    label: const Text('Discover available models'),
                  ),
                ),
              ],
              if (_authenticationMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _authenticationMessage!,
                  style:
                      TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('worker-default-model'),
                controller: _defaultModel,
                decoration: InputDecoration(
                  labelText: _type.authStrategy == 'local_endpoint'
                      ? 'Default Model'
                      : 'Default Model (optional)',
                  hintText: _type.id == 'openai-api'
                      ? 'gpt-4o'
                      : _type.id == 'gemini-api'
                          ? 'gemini-2.5-flash'
                          : _type.id == 'anthropic-api'
                              ? 'claude-3-7-sonnet'
                              : 'e.g. qwen2.5-coder',
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  helperText: _discoveredModels.isEmpty
                      ? null
                      : 'Discovered: ${_discoveredModels.take(8).join(', ')}',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('worker-allowed-models'),
                controller: _allowedModels,
                decoration: const InputDecoration(
                  labelText: 'Allowed Models (comma separated, optional)',
                  hintText: 'e.g. gpt-4o, gpt-4o-mini',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  helperText:
                      'Limit assignments to specific approved models.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Local Permissions',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
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
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Required tool: ${_type.prerequisite}. This Worker becomes Ready once adapter, prerequisite CLI/tools, authentication, and permissions are verified.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_prerequisiteMessage != null) ...[
                const SizedBox(height: 8),
                Text('Prerequisite check: $_prerequisiteMessage',
                    style: theme.textTheme.bodySmall),
              ],
              if (_adapterMessage != null) ...[
                const SizedBox(height: 8),
                Text('Adapter check: $_adapterMessage',
                    style: theme.textTheme.bodySmall),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                              fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _create,
          child: Text(
            _saving
                ? 'Saving…'
                : widget.worker == null
                    ? 'Validate and create'
                    : 'Save changes',
          ),
        ),
      ],
    );
  }

  static IconData _typeIcon(String id) => switch (id) {
        'codex' => Icons.terminal,
        'antigravity' => Icons.auto_awesome,
        'claude-code' => Icons.code,
        'openai-api' || 'gemini-api' || 'anthropic-api' => Icons.cloud_queue,
        'ollama' => Icons.memory,
        _ => Icons.smart_toy_outlined,
      };

  String _permissionLabel(String permission) => switch (permission) {
        'workstream_filesystem' => 'Read and modify Workstream files',
        'shell_execution' => 'Run local shell commands and tools',
        'network' => 'Connect to network services',
        'network_openai' => 'Send prompts to OpenAI API',
        'network_google' => 'Send prompts to Gemini API',
        'network_anthropic' => 'Send prompts to Anthropic API',
        _ => permission,
      };
}

