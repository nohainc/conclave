part of '../spaces_pages.dart';

const _threadBindingLabels = {
  'chat': 'Chat',
  'direct': 'Work',
  'research': 'Research',
  'plan': 'Plan',
  'implement': 'Implement',
  'test': 'Test',
  'verify': 'Verify',
};

extension _ThreadConfiguration on _ThreadPageState {
  void _openWorkSettings(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 800),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Work settings',
                          style: Theme.of(context).textTheme.titleLarge),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  AnimatedBuilder(
                    animation: _workSettingsChanges,
                    builder: (_, __) => _workConfigView(includeTitle: false),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _workConfigView({bool includeTitle = true}) {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final defaultWorkflowId = _workConfig['defaultWorkflowId']?.toString() ??
        _workflowCatalog.firstOrNull?.id ??
        '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (includeTitle) ...[
          Text('Work settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
        ],
        Text('Default workflow', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkflows)
          const LinearProgressIndicator()
        else if (_workflowCatalog.isNotEmpty)
          DropdownButtonFormField<String>(
            itemHeight: null,
            initialValue: defaultWorkflowId,
            decoration: const InputDecoration(labelText: 'Default Workflow'),
            items: _currentWorkflows
                .map((workflow) => DropdownMenuItem(
                      value: workflow.id,
                      child: _workflowOption(context, workflow),
                    ))
                .toList(),
            onChanged: !_canConfigureWork || _savingWorkConfig
                ? null
                : (value) {
                    if (value != null) {
                      _updateState(() => _workConfig = {
                            ..._workConfig,
                            'defaultWorkflowId': value,
                          });
                    }
                  },
          ),
        const SizedBox(height: 12),
        Text('Workers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkChoices)
          const LinearProgressIndicator()
        else ...[
          if (_spaceWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Connect a Workspace and create a ready logical Worker before assigning Steps.',
              ),
            )
          else if (_eligibleWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No logical Workers are Ready yet. Check Profile readiness in Workspace.',
              ),
            ),
          ..._threadBindingLabels.keys.map((bindingId) {
            final raw = bindings[bindingId];
            final binding = raw is Map
                ? Map<String, dynamic>.from(raw)
                : <String, dynamic>{};
            final localWorkerId = binding['workerId']?.toString() ?? '';
            final selectedWorker = _spaceWorkers
                .where((worker) => worker.id == localWorkerId)
                .firstOrNull;
            final catalogUnavailable = selectedWorker != null &&
                (selectedWorker.catalogLifecycleState != 'active' ||
                    selectedWorker.catalogVisibilityState != 'visible');
            final unavailable = localWorkerId.isNotEmpty &&
                (selectedWorker == null || catalogUnavailable);
            final selectedId = unavailable ? '' : localWorkerId;
            final previousLabel = _bindingWorkerLabel(
              binding,
              'workerLabel',
              selectedWorker,
              localWorkerId,
            );
            final status = unavailable
                ? 'Unavailable'
                : selectedWorker == null
                    ? (localWorkerId.isEmpty ? 'Not assigned' : 'Unavailable')
                    : _workerReadinessLabel(selectedWorker);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 100, child: Text(_stepDisplayName(bindingId))),
                  Expanded(
                    child: unavailable
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Worker unavailable',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.error,
                                    ),
                              ),
                              Text('Previously: $previousLabel'),
                              DropdownButtonFormField<String>(
                                key: ValueKey('worker-binding-$bindingId'),
                                isExpanded: true,
                                initialValue: '',
                                decoration: const InputDecoration(
                                  labelText: 'Select Worker',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  const DropdownMenuItem(
                                    value: '',
                                    child: Text('Select Worker'),
                                  ),
                                  ..._eligibleWorkers
                                      .map((worker) => DropdownMenuItem(
                                            value: worker.id,
                                            child: Text(
                                              '${worker.displayName} · ${worker.workspaceName}',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          )),
                                ],
                                onChanged: !_canConfigureWork ||
                                        _savingWorkConfig
                                    ? null
                                    : (value) {
                                        if (value == null || value.isEmpty) {
                                          return;
                                        }
                                        final worker =
                                            _eligibleWorkers.firstWhere(
                                                (item) => item.id == value);
                                        _setStepBinding(bindingId, {
                                          ...binding,
                                          'workerId': worker.id,
                                          'workerLabel': _workerLabel(worker),
                                        });
                                      },
                              ),
                            ],
                          )
                        : DropdownButtonFormField<String>(
                            key: ValueKey('worker-binding-$bindingId'),
                            isExpanded: true,
                            initialValue: selectedId,
                            decoration: const InputDecoration(
                              labelText: 'Worker',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('Choose a Worker'),
                              ),
                              if (selectedWorker != null &&
                                  !_eligibleWorkers.any(
                                      (worker) => worker.id == localWorkerId))
                                DropdownMenuItem(
                                  enabled: false,
                                  value: localWorkerId,
                                  child: Text(
                                    '${selectedWorker.displayName} · ${selectedWorker.workspaceName}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ..._eligibleWorkers
                                  .map((worker) => DropdownMenuItem(
                                        value: worker.id,
                                        child: Text(
                                          '${worker.displayName} · ${worker.workspaceName}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      )),
                            ],
                            onChanged: !_canConfigureWork || _savingWorkConfig
                                ? null
                                : (value) {
                                    if (value == null || value.isEmpty) return;
                                    final worker = _eligibleWorkers
                                        .firstWhere((item) => item.id == value);
                                    _setStepBinding(bindingId, {
                                      ...binding,
                                      'workerId': worker.id,
                                      'workerLabel': _workerLabel(worker),
                                    });
                                  },
                          ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: Text(
                      status,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: status == 'Ready'
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Space instructions',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(widget.space.instructions.trim().isEmpty
                  ? 'None set'
                  : widget.space.instructions),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Edit these in Space settings.'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _threadInstructionsController,
              minLines: 2,
              maxLines: 5,
              maxLength: 4000,
              enabled: _canConfigureWork && !_savingWorkConfig,
              decoration: const InputDecoration(
                labelText: 'Thread instructions',
                helperText: 'Applied to every Step.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _updateState(() => _workConfig = {
                    ..._workConfig,
                    'threadInstructions': value,
                  }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Step settings',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            ..._threadBindingLabels.keys.map((bindingId) {
              final raw = bindings[bindingId];
              final binding = raw is Map
                  ? Map<String, dynamic>.from(raw)
                  : <String, dynamic>{};
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_stepDisplayName(bindingId)),
                subtitle: Text(_stepAdvancedSummary(binding)),
                trailing: TextButton(
                  key: ValueKey('configure-binding-$bindingId'),
                  onPressed: !_canConfigureWork || _savingWorkConfig
                      ? null
                      : () => _editStepBinding(bindingId, binding),
                  child: const Text('Configure'),
                ),
              );
            }),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Concurrency'),
              subtitle: Text('Work Requests are queued for this Thread.'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: !_canConfigureWork || _savingWorkConfig
              ? null
              : () => _saveWorkConfig(_workConfig),
          icon: _savingWorkConfig
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('Save Work settings'),
        ),
        if (!_canConfigureWork)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Only the Space owner or assigned Thread lead can change Work settings.'),
          ),
      ],
    );
  }

  String _stepDisplayName(String bindingId) =>
      _threadBindingLabels[bindingId] ?? bindingId;

  String _workerReadinessLabel(AxWorker worker) {
    if (worker.activationState != 'enabled') return 'Disabled';
    if (worker.readinessState == 'ready') return 'Ready';
    if (worker.attentionReasonCode == 'sign_in_required' ||
        worker.readinessState == 'sign_in_required') {
      return 'Needs sign-in';
    }
    return 'Needs attention';
  }

  Map<String, String> _workerLabel(AxWorker worker) => {
        'displayName': worker.displayName,
        'workspaceName': worker.workspaceName,
      };

  String _bindingWorkerLabel(
    Map<String, dynamic> binding,
    String labelKey,
    AxWorker? inventoryWorker,
    String workerId,
  ) {
    final rawLabel = binding[labelKey];
    if (rawLabel is Map) {
      final displayName = rawLabel['displayName']?.toString().trim() ?? '';
      final workspaceName = rawLabel['workspaceName']?.toString().trim() ?? '';
      if (displayName.isNotEmpty && workspaceName.isNotEmpty) {
        return '$displayName — $workspaceName';
      }
    }
    if (inventoryWorker != null) {
      return '${inventoryWorker.displayName} — ${inventoryWorker.workspaceName}';
    }
    return workerId.isEmpty ? 'Unknown Worker' : 'Worker $workerId';
  }

  String _stepAdvancedSummary(Map<String, dynamic> binding) {
    final details = <String>[];
    if ((binding['additionalInstructions']?.toString().trim().isNotEmpty ??
        false)) {
      details.add('Step instructions');
    }
    if ((binding['model']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Model: ${binding['model']}');
    }
    if ((binding['fallbackWorkerId']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Fallback set');
    }
    return details.isEmpty
        ? 'Instructions, model, and fallback'
        : details.join(' · ');
  }

  void _setStepBinding(String bindingId, Map<String, dynamic> binding) {
    _composerBindings.remove(bindingId);
    _workerPreferences.remove(bindingId);
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final cleaned = Map<String, dynamic>.from(binding)
      ..removeWhere((key, value) => value == null || value == '');
    if (cleaned.isEmpty) {
      bindings.remove(bindingId);
    } else {
      bindings[bindingId] = cleaned;
    }
    _updateState(() => _workConfig = {..._workConfig, 'bindings': bindings});
    _workSettingsChanges.value++;
  }

  Future<void> _editStepBinding(
    String bindingId,
    Map<String, dynamic> current,
  ) async {
    final modelController =
        TextEditingController(text: current['model']?.toString() ?? '');
    final instructionsController = TextEditingController(
      text: current['additionalInstructions']?.toString() ?? '',
    );
    final eligibleWorkerIds =
        _eligibleWorkers.map((worker) => worker.id).toSet();
    final selectedWorker = current['workerId']?.toString() ?? '';
    var fallbackWorker = current['fallbackWorkerId']?.toString() ?? '';
    final originalFallbackWorker = fallbackWorker;
    var fallbackWasChanged = false;
    final fallbackUnavailable = fallbackWorker.isNotEmpty &&
        (!eligibleWorkerIds.contains(fallbackWorker) ||
            fallbackWorker == selectedWorker);
    const clearFallbackValue = '__clear_fallback__';
    final previousFallbackLabel = _bindingWorkerLabel(
      current,
      'fallbackWorkerLabel',
      _spaceWorkers
          .where((worker) => worker.id == originalFallbackWorker)
          .firstOrNull,
      originalFallbackWorker,
    );
    ModalRoute<dynamic>? settingsRoute;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        settingsRoute = ModalRoute.of(dialogContext);
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('${_stepDisplayName(bindingId)} settings'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    if (selectedWorker.isNotEmpty &&
                        !eligibleWorkerIds.contains(selectedWorker)) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Worker unavailable. Previously: ${_bindingWorkerLabel(current, 'workerLabel', _spaceWorkers.where((worker) => worker.id == selectedWorker).firstOrNull, selectedWorker)}',
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (fallbackUnavailable) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Fallback Worker unavailable. Previously: $previousFallbackLabel',
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: fallbackUnavailable
                          ? ''
                          : fallbackWorker.isEmpty
                              ? clearFallbackValue
                              : fallbackWorker,
                      decoration: InputDecoration(
                          labelText: fallbackUnavailable
                              ? 'Select Worker'
                              : 'Fallback Worker (optional)'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Select Worker'),
                        ),
                        const DropdownMenuItem(
                          value: clearFallbackValue,
                          child: Text('No fallback'),
                        ),
                        ..._eligibleWorkers
                            .where((worker) => worker.id != selectedWorker)
                            .map((worker) => DropdownMenuItem(
                                  value: worker.id,
                                  child: Text(
                                    '${worker.displayName} · ${worker.workspaceName}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                )),
                      ],
                      onChanged: (value) => setDialogState(() {
                        fallbackWasChanged = true;
                        fallbackWorker =
                            value == clearFallbackValue ? '' : value ?? '';
                      }),
                    ),
                    TextField(
                      controller: modelController,
                      decoration:
                          const InputDecoration(labelText: 'Model (optional)'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: instructionsController,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 4000,
                      decoration: const InputDecoration(
                        labelText: 'Step instructions (optional)',
                        helperText:
                            'Added to this Step. Conclave manages its built-in guidance.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (saved == true && mounted) {
      final binding = Map<String, dynamic>.from(current);
      if (fallbackWasChanged) {
        if (fallbackWorker.isEmpty) {
          binding.remove('fallbackWorkerId');
          binding.remove('fallbackWorkerLabel');
        } else {
          final worker = _eligibleWorkers
              .where((item) => item.id == fallbackWorker)
              .firstOrNull;
          binding['fallbackWorkerId'] = fallbackWorker;
          if (worker != null) {
            binding['fallbackWorkerLabel'] = _workerLabel(worker);
          }
        }
      } else if (fallbackWorker != originalFallbackWorker) {
        binding['fallbackWorkerId'] = originalFallbackWorker;
      }
      final model = modelController.text.trim();
      final instructions = instructionsController.text.trim();
      if (model.isNotEmpty) binding['model'] = model;
      if (instructions.isNotEmpty) {
        binding['additionalInstructions'] = instructions;
      }
      _setStepBinding(bindingId, binding);
    }
    await settingsRoute?.completed;
    modelController.dispose();
    instructionsController.dispose();
  }
}
