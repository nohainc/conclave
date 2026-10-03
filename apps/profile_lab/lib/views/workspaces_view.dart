import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

class WorkspacesView extends StatefulWidget {
  const WorkspacesView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<WorkspacesView> createState() => _WorkspacesViewState();
}

class _WorkspacesViewState extends State<WorkspacesView> {
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    if (widget.controller.currentSession != null) {
      widget.controller.fetchWorkspaceChannels();
    }
  }

  Color _channelColor(String channel) {
    switch (channel.toLowerCase()) {
      case 'testing':
        return const Color(0xFFA855F7); // Purple
      case 'beta':
        return const Color(0xFF06B6D4); // Cyan
      case 'stable':
      default:
        return const Color(0xFF10B981); // Emerald
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final allWorkspaces = c.workspaceChannels;
    final filtered = allWorkspaces.where((w) {
      if (_searchQuery.isEmpty) return true;
      final name = (w['name'] as String? ?? '').toLowerCase();
      final id = (w['id'] as String? ?? '').toLowerCase();
      final host = (w['hostname'] as String? ?? '').toLowerCase();
      final q = _searchQuery.toLowerCase();
      return name.contains(q) || id.contains(q) || host.contains(q);
    }).toList();

    final testingCount = allWorkspaces
        .where((w) => (w['channel'] as String? ?? 'stable') == 'testing')
        .length;
    final betaCount = allWorkspaces
        .where((w) => (w['channel'] as String? ?? 'stable') == 'beta')
        .length;
    final stableCount = allWorkspaces
        .where((w) => (w['channel'] as String? ?? 'stable') == 'stable')
        .length;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Operational Rollout Path Banner
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: ProfileLabTheme.darkSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.alt_route,
                        color: ProfileLabTheme.primaryAccent, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'CONTROLLED WORKSPACE ROLLOUT PATH',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: ProfileLabTheme.primaryAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _buildPathStep(
                        '1. Local Lab Test', 'Unsigned Sandbox', Colors.grey),
                    _buildStepArrow(),
                    _buildPathStep('2. Testing Workspace',
                        'Your Mac / Test Rig', const Color(0xFFA855F7)),
                    _buildStepArrow(),
                    _buildPathStep('3. Beta Machines', 'Pilot Workspaces',
                        const Color(0xFF06B6D4)),
                    _buildStepArrow(),
                    _buildPathStep('4. Stable Global', 'All Workspaces',
                        const Color(0xFF10B981)),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Tool Profile channels dynamically control which signed worker releases are dispatched to workspace runtimes without altering Workspace binaries. Normal Workspace users do not see or manage channel controls.',
                  style: TextStyle(
                      fontSize: 11, color: Color(0xFF94A3B8), height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Toolbar & Summary Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                SizedBox(
                  width: 200,
                  height: 36,
                  child: TextField(
                    onChanged: (val) => setState(() => _searchQuery = val),
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'Search workspaces...',
                      prefixIcon: const Icon(Icons.search,
                          size: 16, color: Color(0xFF64748B)),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 0, horizontal: 12),
                      filled: true,
                      fillColor: ProfileLabTheme.darkSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _buildCountBadge('Total: ${allWorkspaces.length}', Colors.grey),
                const SizedBox(width: 6),
                _buildCountBadge(
                    'Testing: $testingCount', const Color(0xFFA855F7)),
                const SizedBox(width: 6),
                _buildCountBadge('Beta: $betaCount', const Color(0xFF06B6D4)),
                const SizedBox(width: 6),
                _buildCountBadge(
                    'Stable: $stableCount', const Color(0xFF10B981)),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: c.isLoadingWorkspaces
                      ? null
                      : () => c.fetchWorkspaceChannels(),
                  icon: c.isLoadingWorkspaces
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (c.workspaceError != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF451A1A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: ProfileLabTheme.failColor),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: ProfileLabTheme.failColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Error loading workspace rollout channels: ${c.workspaceError}',
                      style: const TextStyle(
                          fontSize: 12, color: ProfileLabTheme.failColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Workspaces List / Table
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: ProfileLabTheme.darkSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.devices,
                              size: 40, color: Color(0xFF64748B)),
                          const SizedBox(height: 12),
                          Text(
                            c.isLoadingWorkspaces
                                ? 'Loading Workspace channels...'
                                : 'No registered Workspaces found.',
                            style: const TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 13),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: filtered.length,
                      separatorBuilder: (ctx, idx) =>
                          const Divider(color: Color(0xFF334155), height: 1),
                      itemBuilder: (ctx, idx) {
                        final ws = filtered[idx];
                        final wsId = ws['id'] as String;
                        final name = ws['name'] as String? ?? wsId;
                        final channel = (ws['channel'] as String? ?? 'stable')
                            .toLowerCase();
                        final host = ws['hostname'] as String? ?? 'n/a';
                        final platform = ws['platform'] as String? ?? 'n/a';
                        final appVer = ws['appVersion'] as String? ?? 'n/a';
                        final color = _channelColor(channel);

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: color.withValues(alpha: 0.4)),
                                ),
                                child: Icon(Icons.computer,
                                    color: color, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      wsId,
                                      style: const TextStyle(
                                          fontFamily: 'Menlo',
                                          fontSize: 10,
                                          color: Color(0xFF94A3B8)),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      host,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFFE2E8F0)),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '$platform · app v$appVer',
                                      style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF94A3B8)),
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: color.withValues(alpha: 0.5)),
                                ),
                                child: Text(
                                  channel.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: color,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 24),
                              // Channel Selector Dropdown
                              SizedBox(
                                width: 130,
                                height: 32,
                                child: DropdownButtonFormField<String>(
                                  initialValue: channel,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 0),
                                    filled: true,
                                    fillColor: const Color(0xFF1E293B),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                      borderSide: const BorderSide(
                                          color: Color(0xFF334155)),
                                    ),
                                  ),
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white),
                                  dropdownColor: const Color(0xFF1E293B),
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'testing',
                                        child: Text('TESTING')),
                                    DropdownMenuItem(
                                        value: 'beta', child: Text('BETA')),
                                    DropdownMenuItem(
                                        value: 'stable', child: Text('STABLE')),
                                  ],
                                  onChanged: (newChannel) {
                                    if (newChannel != null &&
                                        newChannel != channel) {
                                      c.updateWorkspaceChannel(
                                          wsId, newChannel);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPathStep(String title, String subtitle, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepArrow() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Icon(Icons.arrow_forward, size: 14, color: Color(0xFF64748B)),
    );
  }

  Widget _buildCountBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
