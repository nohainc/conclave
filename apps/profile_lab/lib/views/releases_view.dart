import 'dart:convert';
import 'package:conclave_design/conclave_design.dart';
import '../utils/profile_domain_diff.dart';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';
import 'profile_release_diff_view.dart';
import 'release_evidence_view.dart';
import 'promotion_gate_dialog.dart';
import 'profile_lab_step_up.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

/// The Releases surface contains lifecycle history, channel promotion, and safe rollback.
class ReleasesView extends StatefulWidget {
  const ReleasesView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<ReleasesView> createState() => _ReleasesViewState();
}

class _ReleasesViewState extends State<ReleasesView> {
  void _showRollbackDialog() {
    final c = widget.controller;
    final defId = c.selectedDefinitionId ?? '';
    final releases = c.cloudReleases.where((r) {
      final state = (r['lifecycleState'] as String? ?? '').toLowerCase();
      return state != 'draft' && state != 'revoked' && state != 'retired';
    }).toList();

    String selectedChannel = 'stable';
    int? selectedTargetVersion;
    final reasonController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.undo,
                  color: ProfileLabTheme.warnColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Rollback Channel Pointer for $defId'),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ProfileLabTheme.warnColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color:
                            ProfileLabTheme.warnColor.withValues(alpha: 0.4)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CHANNEL POINTER ROLLBACK (NON-DESTRUCTIVE)',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: ProfileLabTheme.warnColor),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Rollback shifts the target channel pointer (e.g. STABLE from v19 to v18) back to a prior published release. Target release v18 remains published and valid. Later releases (v19) remain in release history and are NOT revoked.',
                        style: TextStyle(
                            fontSize: 11, color: Colors.white, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Select target channel to roll back:',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: selectedChannel,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                        value: 'stable', child: Text('STABLE Channel')),
                    DropdownMenuItem(
                        value: 'beta', child: Text('BETA Channel')),
                    DropdownMenuItem(
                        value: 'testing', child: Text('TESTING Channel')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDlgState(() => selectedChannel = val);
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text('Target prior known-good release version:',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropdownButton<int>(
                  value: selectedTargetVersion,
                  isExpanded: true,
                  hint: const Text('Select prior published release'),
                  items: releases.map((r) {
                    final ver = r['releaseVersion'] as int;
                    final state = r['lifecycleState'] as String;
                    return DropdownMenuItem<int>(
                      value: ver,
                      child: Text('Release v$ver ($state)'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setDlgState(() => selectedTargetVersion = val);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  onChanged: (_) => setDlgState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Mandatory Rollback Reason',
                    hintText: 'e.g. Provider CLI regression in latest release',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.warnColor),
              onPressed: selectedTargetVersion == null ||
                      reasonController.text.trim().isEmpty
                  ? null
                  : () async {
                      Navigator.of(ctx).pop();
                      try {
                        await c.rollbackChannelPointer(
                          channel: selectedChannel,
                          targetReleaseVersion: selectedTargetVersion!,
                          reason: reasonController.text.trim(),
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: CopyableMessage(
                                    'Successfully rolled back $selectedChannel to v$selectedTargetVersion')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          showProfileLabOperationFailure(
                            context,
                            c,
                            'Rollback',
                            e,
                          );
                        }
                      }
                    },
              child: const Text('Execute Channel Rollback',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _showRevokeDialog(Map<String, dynamic> release) {
    final c = widget.controller;
    final ver = release['releaseVersion'] as int;
    final reasonController = TextEditingController();
    final confirmTextController = TextEditingController();
    final expectedConfirmText = 'REVOKE-v$ver';

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final isConfirmed =
              confirmTextController.text.trim() == expectedConfirmText &&
                  reasonController.text.trim().isNotEmpty;

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.block,
                    color: ProfileLabTheme.failColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('PERMANENT RELEASE REVOCATION: v$ver'),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.failColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color:
                              ProfileLabTheme.failColor.withValues(alpha: 0.5)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'REVOCATION IS PERMANENT & IMMEDIATE',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: ProfileLabTheme.failColor),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Revoking a release permanently bans it across all channels, gateways, and worker engines. It can NEVER be selected or executed again by any workspace. Do not use revocation to shift a channel pointer; use Channel Rollback instead.',
                          style: TextStyle(
                              fontSize: 11, color: Colors.white, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: reasonController,
                    onChanged: (_) => setDlgState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Mandatory Revocation Reason',
                      hintText:
                          'e.g. Critical security flaw in CLI execution arguments',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Step-up Confirmation: Type "$expectedConfirmText" to confirm:',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: ProfileLabTheme.secondaryText),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: confirmTextController,
                    onChanged: (_) => setDlgState(() {}),
                    decoration: InputDecoration(
                      hintText: expectedConfirmText,
                      focusedBorder: const OutlineInputBorder(
                        borderSide:
                            BorderSide(color: ProfileLabTheme.failColor),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.failColor,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.gavel, size: 16),
                label: const Text('PERMANENTLY REVOKE RELEASE'),
                onPressed: !isConfirmed
                    ? null
                    : () async {
                        Navigator.of(ctx).pop();
                        try {
                          await c.revokeCloudRelease(
                            releaseVersion: ver,
                            reason: reasonController.text.trim(),
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: CopyableMessage(
                                      'Permanently revoked release v$ver')),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            showProfileLabOperationFailure(
                              context,
                              c,
                              'Revocation',
                              e,
                            );
                          }
                        }
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showPromoteDialog(Map<String, dynamic> release) async {
    final c = widget.controller;
    final currentState = release['lifecycleState'] as String? ?? 'testing';
    final targetChannel = currentState == 'testing' ? 'beta' : 'stable';
    if (targetChannel == 'stable') {
      await c.fetchCloudEvidence(
        profileDefinitionId: c.selectedDefinitionId,
        version: release['releaseVersion'] as int?,
      );
    }
    if (!mounted) return;

    PromotionGateDialog.show(
      context: context,
      controller: c,
      release: release,
      targetChannel: targetChannel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final releases = c.cloudReleases
        .where((r) => r['lifecycleState'] != 'draft')
        .toList()
      ..sort((a, b) =>
          (b['releaseVersion'] as int).compareTo(a['releaseVersion'] as int));
    final selected = c.selectedCloudRelease;
    final channels = c.selectedCloudDefinition?['channels'] as Map? ?? {};
    final canManage =
        c.currentSession != null && c.labAccess?.releaseManager == true;
    if (c.selectedDefinitionId == null) {
      return const Center(child: Text('Select a Worker to view its releases.'));
    }
    final inspector = selected == null || selected['lifecycleState'] == 'draft'
        ? const Padding(
            padding: EdgeInsets.all(LabSpace.page),
            child: Text('Select a release to inspect it.'))
        : _ReleaseInspectorPane(
            controller: c,
            release: selected,
            releases: releases,
            onPromote: canManage && !c.isPromoting
                ? () => _showPromoteDialog(selected)
                : null,
            onRevoke: canManage && !c.isRevoking
                ? () => _showRevokeDialog(selected)
                : null,
            onRollback:
                canManage && !c.isRollingBack ? _showRollbackDialog : null);
    return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(LabSpace.medium),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LabPageHeader(title: 'Release channels', actions: [
                    IconButton(
                        tooltip: 'Refresh Releases (⌘R)',
                        icon: const Icon(Icons.refresh),
                        onPressed: c.isLoadingReleases
                            ? null
                            : () => c.fetchCloudReleases())
                  ]),
                  if (c.isLoadingReleases)
                    const OperationProgress(label: 'Loading…'),
                  if (c.releasesError != null)
                    ErrorState(
                        message: c.releasesError!,
                        onRetry: c.isLoadingReleases
                            ? null
                            : () => c.fetchCloudReleases()),
                  if (c.definitionsError != null) Text(c.definitionsError!),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final channel in ['Testing', 'Beta', 'Stable'])
                      SizedBox(
                          width: constraints.maxWidth < 550
                              ? constraints.maxWidth - 32
                              : (constraints.maxWidth - 56) / 3,
                          child: ReleaseChannelCard(
                              channel: channel,
                              version: channels[channel.toLowerCase()] == null
                                  ? null
                                  : 'v${channels[channel.toLowerCase()]}'))
                  ]),
                  const SizedBox(height: 24),
                  const Text('Release history',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  if (releases.isEmpty)
                    EmptyState(
                        title: 'No published Profile yet',
                        action: FilledButton(
                            onPressed: () =>
                                c.setWorkerSubView(WorkerSubView.draftAndTest),
                            child: const Text('Draft & Test')))
                  else if (constraints.maxWidth >= 900)
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 280, child: _history(c, releases)),
                          const SizedBox(width: 20),
                          Expanded(child: inspector)
                        ])
                  else ...[
                    _history(c, releases),
                    const SizedBox(height: 16),
                    inspector
                  ],
                ])));
  }

  Widget _history(
          ProfileLabController c, List<Map<String, dynamic>> releases) =>
      Card(
          child: Column(children: [
        for (final release in releases)
          ListTile(
              selected: c.selectedCloudRelease?['releaseVersion'] ==
                  release['releaseVersion'],
              title: Text('v${release['releaseVersion']}'),
              subtitle: Text(
                  '${release['lifecycleState']} · ${release['publishedAt'] ?? 'Published time unavailable'}'),
              onTap: () => c.selectCloudRelease(release))
      ]));
}

class _ReleaseInspectorPane extends StatelessWidget {
  const _ReleaseInspectorPane(
      {required this.controller,
      required this.release,
      required this.releases,
      this.onPromote,
      this.onRevoke,
      this.onRollback});
  final ProfileLabController controller;
  final Map<String, dynamic> release;
  final List<Map<String, dynamic>> releases;
  final VoidCallback? onPromote, onRevoke, onRollback;

  @override
  Widget build(BuildContext context) {
    final version = release['releaseVersion'] as int;
    final state = release['lifecycleState'] as String? ?? '';
    final profile = release['profile'] as Map<String, dynamic>? ?? {};
    final previous = releases
        .where((r) => (r['releaseVersion'] as int) < version)
        .firstOrNull;
    final changes = previous == null
        ? <DomainDiffGroup>[]
        : ProfileDomainDiffCalculator.computeDiff(
                previous['profile'] as Map<String, dynamic>?, profile)
            .where((g) => g.hasChanges)
            .toList();
    final provider = profile['providerTool'] as Map? ?? {};
    final ranges = provider['supportedVersions'] as List? ?? [];
    final compatibility =
        '${provider['name'] ?? 'Unknown provider'} · ${ranges.map((r) => "${r['min']} ≤ version < ${r['maxExclusive']}").join(', ')}';
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(LabSpace.medium),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text('Release v$version',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold))),
                    PopupMenuButton<String>(
                        tooltip: 'Release actions',
                        onSelected: (action) {
                          if (action == 'rollback') onRollback?.call();
                          if (action == 'revoke') onRevoke?.call();
                          if (action == 'draft') {
                            controller.createDraftFromRelease(
                                profileDefinitionId:
                                    controller.selectedDefinitionId!,
                                releasePayload: profile);
                          }
                        },
                        itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'draft',
                                  child: Text('Create next Draft')),
                              const PopupMenuDivider(),
                              PopupMenuItem(
                                  value: 'rollback',
                                  enabled: onRollback != null,
                                  child: const Text('Rollback channel…',
                                      style: TextStyle(
                                          color: ProfileLabTheme.warnColor))),
                              if (state != 'revoked')
                                PopupMenuItem(
                                    value: 'revoke',
                                    enabled: onRevoke != null,
                                    child: const Text('Revoke release…',
                                        style: TextStyle(
                                            color: ProfileLabTheme.failColor)))
                            ])
                  ]),
                  _PropertyRow(label: 'Status', value: state),
                  _PropertyRow(
                      label: 'Published',
                      value: '${release['publishedAt'] ?? 'Unavailable'}'),
                  _PropertyRow(
                      label: 'Provider compatibility', value: compatibility),
                  if (state == 'revoked')
                    _PropertyRow(
                        label: 'Revocation reason',
                        value:
                            '${release['lifecycleReason'] ?? 'Unavailable'}'),
                  if (state == 'testing' || state == 'beta') ...[
                    const SizedBox(height: 12),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                            icon: const Icon(Icons.arrow_upward, size: 16),
                            onPressed: onPromote,
                            label: Text(state == 'testing'
                                ? 'Promote to Beta'
                                : 'Promote to Stable')))
                  ],
                  const SizedBox(height: 16),
                  ReleaseEvidenceView(controller: controller, release: release),
                  const SizedBox(height: 16),
                  const Text('Changes from previous version',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  if (previous == null)
                    const Text('First published version — no previous release.')
                  else ...[
                    Text(changes.isEmpty
                        ? 'No implementation changes.'
                        : changes
                            .map((g) =>
                                '${g.domainName}: ${g.changeCount} changes')
                            .join(' · ')),
                    TextButton.icon(
                        icon: const Icon(Icons.compare_arrows),
                        label:
                            Text('Compare with v${previous['releaseVersion']}'),
                        onPressed: () => ProfileReleaseDiffDialog.show(context,
                            titleA: 'Release v${previous['releaseVersion']}',
                            payloadA:
                                previous['profile'] as Map<String, dynamic>?,
                            titleB: 'Release v$version',
                            payloadB: profile)),
                  ],
                  TechnicalInspector(children: [
                    _PropertyRow(
                        label: 'Publisher',
                        value: '${release['publisher'] ?? 'Unavailable'}'),
                    _PropertyRow(
                        label: 'Signing key',
                        value: '${release['signingKeyId'] ?? 'Unavailable'}'),
                    _PropertyRow(
                        label: 'Payload digest',
                        value: '${release['payloadDigest'] ?? ''}',
                        isMonospace: true),
                    SelectableText(
                        const JsonEncoder.withIndent('  ').convert(profile),
                        style: ConclaveTypography.monoSmall)
                  ]),
                ])));
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: ProfileLabTheme.secondaryText)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily:
                    isMonospace ? ConclaveTypography.fontFamilyMono : null,
                fontFamilyFallback: isMonospace
                    ? ConclaveTypography.fontFamilyMonoFallback
                    : null,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
