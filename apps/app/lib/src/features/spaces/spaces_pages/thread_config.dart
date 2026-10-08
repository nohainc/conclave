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
        const Text(
            'Worker, model, and effort defaults are configured on the Workflows page.'),
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

  String _stepAdvancedSummary(Map<String, dynamic> binding) {
    final details = <String>[];
    if ((binding['additionalInstructions']?.toString().trim().isNotEmpty ??
        false)) {
      details.add('Step instructions');
    }
    return details.isEmpty ? 'Step instructions' : details.join(' · ');
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
    _workSettingsChanges.value++;
  }

  Future<void> _editStepBinding(
      String bindingId, Map<String, dynamic> current) async {
    final controller = TextEditingController(
        text: current['additionalInstructions']?.toString() ?? '');
    ModalRoute<dynamic>? route;
    final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          route = ModalRoute.of(dialogContext);
          return AlertDialog(
              title: Text('${_stepDisplayName(bindingId)} instructions'),
              content: SizedBox(
                  width: 460,
                  child: TextField(
                      controller: controller,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 4000,
                      decoration: const InputDecoration(
                          labelText: 'Step instructions (optional)'))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Save'))
              ]);
        });
    if (saved == true && mounted) {
      _setStepBinding(
          bindingId, {'additionalInstructions': controller.text.trim()});
    }
    await route?.completed;
    controller.dispose();
  }
}
