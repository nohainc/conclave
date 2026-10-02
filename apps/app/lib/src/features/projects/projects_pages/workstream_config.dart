part of '../projects_pages.dart';

extension _WorkstreamConfiguration on _WorkstreamPageState {
  Widget _workConfigView() {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final defaultWorkflowId = _workConfig['defaultWorkflowId']?.toString() ??
        _workflowCatalog.firstOrNull?.id ??
        '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Work settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        Text('Default workflow', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkflows)
          const LinearProgressIndicator()
        else if (_workflowCatalog.isNotEmpty)
          DropdownButtonFormField<String>(
            itemHeight: null,
            initialValue: defaultWorkflowId,
            decoration: const InputDecoration(labelText: 'Default Workflow'),
            items: _workflowCatalog
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
          if (_projectWorkers.isEmpty)
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
          ...const [
            'direct',
            'research',
            'plan',
            'implement',
            'test',
            'verify',
          ].map((bindingId) {
            final raw = bindings[bindingId];
            final binding = raw is Map
                ? Map<String, dynamic>.from(raw)
                : <String, dynamic>{};
            final localWorkerId = binding['workerId']?.toString() ?? '';
            final selectedId =
                _eligibleWorkers.any((worker) => worker.id == localWorkerId)
                    ? localWorkerId
                    : '';
            final selectedWorker = _projectWorkers
                .where((worker) => worker.id == localWorkerId)
                .firstOrNull;
            final status = selectedWorker == null
                ? (localWorkerId.isEmpty ? 'Not assigned' : 'Unavailable')
                : _workerReadinessLabel(selectedWorker);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 100, child: Text(_stepDisplayName(bindingId))),
                  Expanded(
                    child: DropdownButtonFormField<String>(
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
                        ..._eligibleWorkers.map((worker) => DropdownMenuItem(
                              value: worker.id,
                              child: Text(
                                '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                      ],
                      onChanged: !_canConfigureWork || _savingWorkConfig
                          ? null
                          : (value) => _setStepBinding(
                                bindingId,
                                value == null || value.isEmpty
                                    ? <String, dynamic>{}
                                    : {...binding, 'workerId': value},
                              ),
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
              child: Text('Project instructions',
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
              child: Text(widget.project.instructions.trim().isEmpty
                  ? 'None set'
                  : widget.project.instructions),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Edit these in Project settings.'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _workstreamInstructionsController,
              minLines: 2,
              maxLines: 5,
              maxLength: 4000,
              enabled: _canConfigureWork && !_savingWorkConfig,
              decoration: const InputDecoration(
                labelText: 'Workstream instructions',
                helperText: 'Applied to every Step.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _updateState(() => _workConfig = {
                    ..._workConfig,
                    'workstreamInstructions': value,
                  }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Step settings',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            ...const [
              'direct',
              'research',
              'plan',
              'implement',
              'test',
              'verify',
            ].map((bindingId) {
              final raw = bindings[bindingId];
              final binding = raw is Map
                  ? Map<String, dynamic>.from(raw)
                  : <String, dynamic>{};
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_stepDisplayName(bindingId)),
                subtitle: Text(_stepAdvancedSummary(binding)),
                trailing: TextButton(
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
              subtitle: Text('Work Requests are queued for this Workstream.'),
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
                'Only the Project owner or assigned Workstream lead can change Work settings.'),
          ),
      ],
    );
  }

  String _stepDisplayName(String bindingId) => switch (bindingId) {
        'direct' => 'Direct',
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        _ => 'Verify',
      };

  String _workerReadinessLabel(AxWorker worker) {
    if (worker.activationState != 'enabled') return 'Disabled';
    if (worker.readinessState == 'ready') return 'Ready';
    if (worker.attentionReasonCode == 'sign_in_required' ||
        worker.readinessState == 'sign_in_required') {
      return 'Needs sign-in';
    }
    return 'Needs attention';
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
  }

  String _workerDisplayName(AxWorker worker) => switch (worker.workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => worker.workerTypeId,
      };

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
    var selectedWorker = current['workerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(selectedWorker)) selectedWorker = '';
    var fallbackWorker = current['fallbackWorkerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(fallbackWorker) ||
        fallbackWorker == selectedWorker) {
      fallbackWorker = '';
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${_stepDisplayName(bindingId)} settings'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: fallbackWorker,
                    decoration: const InputDecoration(
                        labelText: 'Fallback Worker (optional)'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('No fallback')),
                      ..._eligibleWorkers
                          .where((worker) => worker.id != selectedWorker)
                          .map((worker) => DropdownMenuItem(
                                value: worker.id,
                                child: Text(
                                    '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}'),
                              )),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => fallbackWorker = value ?? ''),
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
      ),
    );
    if (saved == true && mounted) {
      final binding = <String, dynamic>{
        if (selectedWorker.isNotEmpty) 'workerId': selectedWorker,
        if (fallbackWorker.isNotEmpty) 'fallbackWorkerId': fallbackWorker,
      };
      final model = modelController.text.trim();
      final instructions = instructionsController.text.trim();
      if (model.isNotEmpty) binding['model'] = model;
      if (instructions.isNotEmpty) {
        binding['additionalInstructions'] = instructions;
      }
      _setStepBinding(bindingId, binding);
    }
    modelController.dispose();
    instructionsController.dispose();
  }
}
