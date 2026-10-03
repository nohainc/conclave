import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

class WorkersView extends StatefulWidget {
  const WorkersView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<WorkersView> createState() => _WorkersViewState();
}

class _WorkersViewState extends State<WorkersView> {
  final TextEditingController _searchController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _filter = _searchController.text.trim().toLowerCase();
      });
    });
    // Auto-fetch catalog if session is active and list is empty
    if (widget.controller.cloudWorkers.isEmpty &&
        widget.controller.currentSession != null) {
      widget.controller.fetchCloudCatalog();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showCreateWorkerDialog() {
    final c = widget.controller;
    final workerTypeIdCtrl = TextEditingController(text: 'claude');
    final definitionIdCtrl = TextEditingController(text: 'claude-code');
    final displayNameCtrl = TextEditingController(text: 'Claude');
    final descriptionCtrl = TextEditingController(
        text: 'Anthropic Claude Code AI Assistant Worker');
    final providerToolCtrl = TextEditingController(text: 'claude');
    final capabilitiesCtrl =
        TextEditingController(text: 'code_generation, tool_execution');
    final sortOrderCtrl = TextEditingController(text: '10');
    String releaseStage = 'draft';

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Create Approved Logical Worker'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Registers a new logical Worker identity and initial Profile Definition atomically in Cloud.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: workerTypeIdCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Stable Worker ID (workerTypeId)',
                      hintText: 'e.g. claude',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: definitionIdCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Initial Profile Definition ID (profileDefinitionId)',
                      hintText: 'e.g. claude-code',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: displayNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Display Name',
                      hintText: 'e.g. Claude',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descriptionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText:
                          'e.g. Anthropic Claude Code AI Assistant Worker',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: providerToolCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Provider Tool Identity (providerToolName)',
                      hintText: 'e.g. claude',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: capabilitiesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Capabilities (comma separated)',
                      hintText: 'e.g. code_generation, tool_execution',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Release Stage:',
                                style: TextStyle(
                                    fontSize: 11, color: Color(0xFF94A3B8))),
                            DropdownButton<String>(
                              value: releaseStage,
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(
                                    value: 'draft', child: Text('Draft')),
                                DropdownMenuItem(
                                    value: 'testing', child: Text('Testing')),
                                DropdownMenuItem(
                                    value: 'beta', child: Text('Beta')),
                                DropdownMenuItem(
                                    value: 'stable', child: Text('Stable')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDlgState(() => releaseStage = val);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: sortOrderCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Sort Order',
                            hintText: '10',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.primaryAccent),
              onPressed: () async {
                final wId = workerTypeIdCtrl.text.trim();
                final pId = definitionIdCtrl.text.trim();
                final dName = displayNameCtrl.text.trim();
                final desc = descriptionCtrl.text.trim();
                final pTool = providerToolCtrl.text.trim();
                final caps = capabilitiesCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                final sortOrder = int.tryParse(sortOrderCtrl.text.trim()) ?? 10;

                if (wId.isEmpty ||
                    pId.isEmpty ||
                    dName.isEmpty ||
                    pTool.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Please fill out all required fields.')),
                  );
                  return;
                }

                Navigator.of(ctx).pop();
                try {
                  await c.createWorkerCatalogEntry(
                    workerTypeId: wId,
                    profileDefinitionId: pId,
                    displayName: dName,
                    description: desc,
                    providerToolName: pTool,
                    releaseStage: releaseStage,
                    capabilities: caps,
                    sortOrder: sortOrder,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content:
                              Text('Successfully created Worker $wId ($pId)')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to create Worker: $e')),
                    );
                  }
                }
              },
              child: const Text('Create Worker',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final workers = c.cloudWorkers.where((w) {
      if (_filter.isEmpty) return true;
      final typeId = (w['workerTypeId'] ?? '').toString().toLowerCase();
      final name = (w['displayName'] ?? '').toString().toLowerCase();
      final tool = (w['providerToolName'] ?? '').toString().toLowerCase();
      return typeId.contains(_filter) ||
          name.contains(_filter) ||
          tool.contains(_filter);
    }).toList();

    return Row(
      children: [
        // Left pane: Workers List
        Container(
          width: 320,
          decoration: const BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            border: Border(right: BorderSide(color: Color(0xFF334155))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Search & refresh header
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'Filter workers...',
                          hintStyle: const TextStyle(
                              fontSize: 12, color: Color(0xFF64748B)),
                          prefixIcon: const Icon(Icons.search,
                              size: 16, color: Color(0xFF94A3B8)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          filled: true,
                          fillColor: ProfileLabTheme.darkBackground,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide:
                                const BorderSide(color: Color(0xFF334155)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide:
                                const BorderSide(color: Color(0xFF334155)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.add, size: 18),
                      tooltip: 'Create Worker + Definition',
                      onPressed: c.currentSession != null
                          ? _showCreateWorkerDialog
                          : null,
                    ),
                    IconButton(
                      icon: c.isLoadingCloud
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ProfileLabTheme.primaryAccent),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      tooltip: 'Refresh Cloud Catalog',
                      onPressed:
                          c.isLoadingCloud ? null : () => c.fetchCloudCatalog(),
                    ),
                  ],
                ),
              ),

              if (c.currentSession == null)
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cloud Catalog Unauthenticated',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: ProfileLabTheme.warnColor),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Sign in with Profile Lab credentials to query the dynamic Cloud catalog.',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.login, size: 14),
                        label: const Text('Sign In to Cloud',
                            style: TextStyle(fontSize: 11)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: ProfileLabTheme.primaryAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => c.signInWithBrowser(),
                      ),
                    ],
                  ),
                ),

              // Workers list
              Expanded(
                child: workers.isEmpty
                    ? Center(
                        child: Text(
                          c.currentSession == null
                              ? 'Sign in to fetch catalog.'
                              : c.isLoadingCloud
                                  ? 'Fetching catalog...'
                                  : 'No logical workers found.',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A3B8)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: workers.length,
                        itemBuilder: (context, index) {
                          final worker = workers[index];
                          final workerTypeId =
                              worker['workerTypeId'] as String? ?? '';
                          final isSelected =
                              c.selectedCloudWorker?['workerTypeId'] ==
                                  workerTypeId;
                          final stage =
                              worker['releaseStage'] as String? ?? 'testing';
                          final toolName =
                              worker['providerToolName'] as String? ?? '';

                          return ListTile(
                            dense: true,
                            selected: isSelected,
                            selectedTileColor: ProfileLabTheme.primaryAccent
                                .withValues(alpha: 0.12),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    worker['displayName'] as String? ??
                                        workerTypeId,
                                    style: TextStyle(
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                _StageBadge(stage: stage),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Text(
                                  workerTypeId,
                                  style: const TextStyle(
                                      fontFamily: 'Menlo',
                                      fontSize: 10,
                                      color: Color(0xFF94A3B8)),
                                ),
                                if (toolName.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    'CLI: $toolName',
                                    style: const TextStyle(
                                        fontSize: 10, color: Color(0xFF64748B)),
                                  ),
                                ],
                              ],
                            ),
                            onTap: () => c.selectWorker(worker),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        // Right pane: Selected Worker Details
        Expanded(
          child: c.selectedCloudWorker == null
              ? const Center(
                  child: Text(
                    'Select a logical worker from the dynamic catalog.',
                    style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                  ),
                )
              : _WorkerDetailsPane(
                  controller: c,
                  worker: c.selectedCloudWorker!,
                  definition: c.selectedCloudDefinition,
                ),
        ),
      ],
    );
  }
}

class _WorkerDetailsPane extends StatelessWidget {
  const _WorkerDetailsPane({
    required this.controller,
    required this.worker,
    required this.definition,
  });

  final ProfileLabController controller;
  final Map<String, dynamic> worker;
  final Map<String, dynamic>? definition;

  @override
  Widget build(BuildContext context) {
    final workerTypeId = worker['workerTypeId'] as String? ?? '';
    final displayName = worker['displayName'] as String? ?? workerTypeId;
    final description =
        worker['description'] as String? ?? 'No description provided.';
    final lifecycleState = worker['lifecycleState'] as String? ?? 'active';
    final visibilityState = worker['visibilityState'] as String? ?? 'visible';
    final releaseStage = worker['releaseStage'] as String? ?? 'stable';
    final sortOrder = worker['sortOrder']?.toString() ?? '100';
    final profileDefId =
        worker['profileDefinitionId'] as String? ?? 'Not configured';
    final providerTool = worker['providerToolName'] as String? ?? 'Unknown';

    final channels =
        (definition?['channels'] as Map?)?.cast<String, dynamic>() ?? {};
    final stableVersion = channels['stable']?.toString() ?? 'None';
    final betaVersion = channels['beta']?.toString() ?? 'None';
    final testingVersion = channels['testing']?.toString() ?? 'None';

    final capabilities =
        (worker['capabilities'] as List?)?.cast<String>() ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              workerTypeId,
                              style: const TextStyle(
                                  fontFamily: 'Menlo',
                                  fontSize: 12,
                                  color: Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                      ),
                      _StatusBadge(
                          label: lifecycleState.toUpperCase(),
                          isPass: lifecycleState == 'active'),
                      const SizedBox(width: 8),
                      _StatusBadge(
                          label: visibilityState.toUpperCase(),
                          isPass: visibilityState == 'visible'),
                      const SizedBox(width: 8),
                      _StageBadge(stage: releaseStage),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    description,
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFFCBD5E1)),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: capabilities
                        .map(
                          (cap) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF334155),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              cap,
                              style: const TextStyle(
                                  fontFamily: 'Menlo',
                                  fontSize: 11,
                                  color: Color(0xFFE2E8F0)),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Channel Releases Matrix
          const Text(
            'ACTIVE CHANNEL POINTERS',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _ChannelPointerCard(
                  channel: 'Testing Channel',
                  version: testingVersion,
                  color: Colors.blueAccent,
                  isTarget: testingVersion != 'None',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ChannelPointerCard(
                  channel: 'Beta Channel',
                  version: betaVersion,
                  color: Colors.purpleAccent,
                  isTarget: betaVersion != 'None',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ChannelPointerCard(
                  channel: 'Stable Channel',
                  version: stableVersion,
                  color: ProfileLabTheme.passColor,
                  isTarget: stableVersion != 'None',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Active Profile Definition Details
          const Text(
            'ACTIVE TOOL PROFILE DEFINITION',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PropertyRow(
                      label: 'Profile Definition ID',
                      value: profileDefId,
                      isMonospace: true),
                  const Divider(color: Color(0xFF334155)),
                  _PropertyRow(label: 'Provider CLI Name', value: providerTool),
                  const Divider(color: Color(0xFF334155)),
                  _PropertyRow(
                      label: 'Engine Family',
                      value: 'cli (generic worker engine)'),
                  const Divider(color: Color(0xFF334155)),
                  _PropertyRow(label: 'Schema Version', value: 'v1'),
                  const Divider(color: Color(0xFF334155)),
                  _PropertyRow(label: 'Sort Order', value: sortOrder),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Action buttons to jump to other surfaces
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit / Test in Profiles'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setTab(LabTab.profiles);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Inspect Releases'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF475569)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setTab(LabTab.releases);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.policy_outlined, size: 16),
                label: const Text('View Audit Trail'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF475569)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setTab(LabTab.audit);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChannelPointerCard extends StatelessWidget {
  const _ChannelPointerCard({
    required this.channel,
    required this.version,
    required this.color,
    required this.isTarget,
  });

  final String channel;
  final String version;
  final Color color;
  final bool isTarget;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isTarget
                ? color.withValues(alpha: 0.5)
                : const Color(0xFF334155),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isTarget ? color : const Color(0xFF64748B),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  channel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isTarget ? color : const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              version == 'None' ? 'Unassigned' : 'Release v$version',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                fontFamily: version == 'None' ? null : 'Menlo',
                color:
                    version == 'None' ? const Color(0xFF64748B) : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StageBadge extends StatelessWidget {
  const _StageBadge({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) {
    final color = switch (stage) {
      'stable' => ProfileLabTheme.passColor,
      'beta' => Colors.purpleAccent,
      _ => Colors.blueAccent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        stage.toUpperCase(),
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.isPass});

  final String label;
  final bool isPass;

  @override
  Widget build(BuildContext context) {
    final color = isPass ? ProfileLabTheme.passColor : const Color(0xFF94A3B8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}

class _PropertyRow extends StatelessWidget {
  const _PropertyRow({
    required this.label,
    required this.value,
    this.isMonospace = false,
  });

  final String label;
  final String value;
  final bool isMonospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: isMonospace ? 'Menlo' : null,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
