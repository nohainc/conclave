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

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.worker == null ? 'Add Worker' : 'Edit Worker'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<LocalWorkerTypeOption>(
                  key: const Key('worker-type-selector'),
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Worker Type'),
                  items: [
                    for (final type in LocalWorkerTypeOption.supported)
                      DropdownMenuItem(value: type, child: Text(type.name))
                  ],
                  onChanged: _saving || widget.worker != null
                      ? null
                      : (type) => setState(() {
                            _type = type!;
                            _endpointUrl.text = type.id == 'ollama'
                                ? 'http://localhost:11434'
                                : '';
                            _permissions.clear();
                            _error = null;
                          }),
                ),
                const SizedBox(height: 8),
                Text(_type.description),
                const SizedBox(height: 12),
                TextField(
                    key: const Key('worker-name'),
                    controller: _name,
                    decoration:
                        const InputDecoration(labelText: 'Worker name')),
                if (_type.requiresApiKey) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('worker-api-key'),
                    controller: _apiKey,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                        labelText: _type.authLabel,
                        helperText:
                            'Stored in this machine’s secure credential store.'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.key),
                    title: Text(_type.authLabel),
                    subtitle: Text(_type.authStrategy == 'browser_auth'
                        ? 'Sign in on this machine. Conclave checks the local session when you save.'
                        : 'Uses a local service; no provider credential is stored.'),
                  ),
                  if (_type.authStrategy == 'browser_auth' &&
                      (_type.id == 'codex' ||
                          _type.id == 'antigravity' ||
                          _type.id == 'claude-code') &&
                      widget.launchAuthentication != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _saving
                            ? null
                            : () async {
                                try {
                                  await widget.launchAuthentication!(_type.id);
                                  if (mounted) {
                                    setState(() => _error =
                                        'Sign-in opened. Complete it, then validate and save.');
                                  }
                                } catch (error) {
                                  if (mounted) {
                                    setState(() => _error =
                                        'Could not start sign-in: $error');
                                  }
                                }
                              },
                        icon: const Icon(Icons.open_in_browser),
                        label: Text('Sign in to ${_type.name}'),
                      ),
                    ),
                ],
                TextField(
                    key: const Key('worker-endpoint'),
                    controller: _endpointUrl,
                    decoration: const InputDecoration(
                        labelText: 'Endpoint URL (optional)',
                        helperText:
                            'Required for local model services. API overrides are optional.')),
                if (_authenticationMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_authenticationMessage!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                if (_type.authStrategy == 'local_endpoint')
                  TextField(
                    key: const Key('worker-default-model'),
                    controller: _defaultModel,
                    decoration: InputDecoration(
                      labelText: 'Default model',
                      helperText: _discoveredModels.isEmpty
                          ? 'Validate the endpoint to discover installed models.'
                          : 'Installed models: ${_discoveredModels.take(12).join(', ')}',
                    ),
                  )
                else
                  TextField(
                    key: const Key('worker-default-model'),
                    controller: _defaultModel,
                    decoration: InputDecoration(
                      labelText: 'Default model (optional)',
                      helperText: _discoveredModels.isEmpty
                          ? null
                          : 'Available models: ${_discoveredModels.take(12).join(', ')}',
                    ),
                  ),
                TextField(
                    key: const Key('worker-allowed-models'),
                    controller: _allowedModels,
                    decoration: const InputDecoration(
                        labelText:
                            'Allowed models (comma separated, optional)')),
                const SizedBox(height: 12),
                Text('Local permissions',
                    style: Theme.of(context).textTheme.titleSmall),
                for (final permission in _type.permissions)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_permissionLabel(permission)),
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
                Text(
                    'Required tool: ${_type.prerequisite}. This Worker will stay in Needs attention until its adapter, prerequisite, authentication, and permissions are ready.'),
                if (_prerequisiteMessage != null) ...[
                  const SizedBox(height: 8),
                  Text('Prerequisite check: $_prerequisiteMessage'),
                ],
                if (_adapterMessage != null) ...[
                  const SizedBox(height: 8),
                  Text('Adapter check: $_adapterMessage'),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _saving ? null : _create,
              child: Text(_saving
                  ? 'Saving…'
                  : widget.worker == null
                      ? 'Validate and create'
                      : 'Save changes')),
        ],
      );

  String _permissionLabel(String permission) => switch (permission) {
        'workstream_filesystem' => 'Read and modify Workstream files',
        'shell_execution' => 'Run local shell tools',
        'network' => 'Connect to network services',
        'network_openai' => 'Send prompts to OpenAI API',
        'network_google' => 'Send prompts to Gemini API',
        'network_anthropic' => 'Send prompts to Anthropic API',
        _ => permission,
      };
}
