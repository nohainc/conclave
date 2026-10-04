import 'dart:convert';
import 'package:flutter/material.dart';
import 'profile_release_diff_view.dart';
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
      return state != 'revoked' && state != 'retired';
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
                            fontSize: 11,
                            color: Color(0xFFE2E8F0),
                            height: 1.4),
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
                                content: Text(
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
                              fontSize: 11,
                              color: Color(0xFFE2E8F0),
                              height: 1.4),
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
                        color: Color(0xFF94A3B8)),
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
                                  content: Text(
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
    final releases = c.cloudReleases;
    final selectedRelease = c.selectedCloudRelease;

    if (c.selectedDefinitionId == null) {
      return const Center(
        child: Text(
            'No Profile Definition selected. Select a Worker or Profile first.',
            style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
      );
    }

    return Column(
      children: [
        // Top Toolbar
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            border: Border(bottom: BorderSide(color: Color(0xFF334155))),
          ),
          child: Row(
            children: [
              Text(
                'RELEASES FOR ${c.selectedDefinitionId}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('${releases.length} releases',
                    style: const TextStyle(
                        fontSize: 10, color: Color(0xFFE2E8F0))),
              ),
              const Spacer(),
              OutlinedButton.icon(
                icon: const Icon(Icons.undo, size: 14),
                label: const Text('Rollback Channel...',
                    style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ProfileLabTheme.warnColor,
                  side: const BorderSide(color: ProfileLabTheme.warnColor),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: releases.length > 1 &&
                        c.currentSession != null &&
                        !c.isRollingBack
                    ? _showRollbackDialog
                    : null,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh Releases',
                onPressed:
                    c.isLoadingReleases ? null : () => c.fetchCloudReleases(),
              ),
            ],
          ),
        ),

        if (c.isLoadingReleases) const LinearProgressIndicator(),
        if (c.releasesError != null) Text(c.releasesError!),

        // Split view: Left Releases Table, Right Release Inspector
        Card(
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          color: Colors.blue.withValues(alpha: 0.10),
          child: const Padding(
            padding: EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.lightBlue, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Stable promotion requires a qualifying evidence record stored by Cloud. Profile Lab submits evidence separately, then promotes by its Cloud evidence ID.',
                    style: TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              // Releases list
              Expanded(
                flex: 5,
                child: releases.isEmpty
                    ? Center(
                        child: Text(
                          c.currentSession == null
                              ? 'Sign in to fetch releases from Cloud.'
                              : 'No releases published yet for this definition.',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A3B8)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: releases.length,
                        itemBuilder: (ctx, i) {
                          final rel = releases[i];
                          final ver = rel['releaseVersion'] as int;
                          final state =
                              rel['lifecycleState'] as String? ?? 'draft';
                          final isSelected =
                              selectedRelease?['releaseVersion'] == ver;
                          final publishedAt =
                              rel['publishedAt'] as String? ?? 'Unpublished';
                          final digest = rel['payloadDigest'] as String? ?? '';

                          return ListTile(
                            dense: true,
                            selected: isSelected,
                            selectedTileColor: ProfileLabTheme.primaryAccent
                                .withValues(alpha: 0.12),
                            leading: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF334155),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text('v$ver',
                                  style: const TextStyle(
                                      fontFamily: 'Menlo',
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                            ),
                            title: Row(
                              children: [
                                _LifecycleBadge(state: state),
                                const SizedBox(width: 8),
                                if (rel['signature'] != null)
                                  const Icon(Icons.verified,
                                      size: 14,
                                      color: ProfileLabTheme.passColor),
                              ],
                            ),
                            subtitle: Text(
                              'Published: $publishedAt\nDigest: ${digest.length > 12 ? "${digest.substring(0, 12)}..." : digest}',
                              style: const TextStyle(
                                  fontFamily: 'Menlo',
                                  fontSize: 10,
                                  color: Color(0xFF94A3B8)),
                            ),
                            isThreeLine: true,
                            trailing: state == 'testing' || state == 'beta'
                                ? IconButton(
                                    icon: const Icon(Icons.upgrade,
                                        size: 18,
                                        color: ProfileLabTheme.primaryAccent),
                                    tooltip: state == 'testing'
                                        ? 'Promote to Beta'
                                        : 'Promote to Stable using Cloud evidence',
                                    onPressed: c.isPromoting
                                        ? null
                                        : () => _showPromoteDialog(rel),
                                  )
                                : null,
                            onTap: () => c.selectCloudRelease(rel),
                          );
                        },
                      ),
              ),
              const VerticalDivider(
                  width: 1, thickness: 1, color: Color(0xFF334155)),

              // Release details & payload inspector
              Expanded(
                flex: 5,
                child: selectedRelease == null
                    ? const Center(
                        child: Text('Select a release to inspect payload.',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF94A3B8))))
                    : _ReleaseInspectorPane(
                        controller: c,
                        release: selectedRelease,
                        onPromote: c.isPromoting
                            ? null
                            : () => _showPromoteDialog(selectedRelease),
                        onRevoke: c.isRevoking
                            ? null
                            : () => _showRevokeDialog(selectedRelease),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReleaseInspectorPane extends StatelessWidget {
  const _ReleaseInspectorPane({
    required this.controller,
    required this.release,
    required this.onPromote,
    required this.onRevoke,
  });

  final ProfileLabController controller;
  final Map<String, dynamic> release;
  final VoidCallback? onPromote;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final ver = release['releaseVersion'] as int;
    final state = release['lifecycleState'] as String? ?? 'draft';
    final profile = release['profile'] as Map<String, dynamic>? ?? {};
    final publisher = release['publisher'] as String? ?? 'conclave';
    final signingKey = release['signingKeyId'] as String? ?? 'unsigned';
    final publishedAt =
        release['publishedAt'] as String? ?? 'Draft (Not published)';
    final digest = release['payloadDigest'] as String? ?? '';

    const encoder = JsonEncoder.withIndent('  ');
    final formattedJson = encoder.convert(profile);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text('Release v$ver Details',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.compare_arrows, size: 14),
                    label: const Text('Diff Domains...',
                        style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                    onPressed: () {
                      final defId =
                          (profile['profileDefinitionId'] as String?) ??
                              (release['profileDefinitionId'] as String?);
                      Map<String, dynamic>? draftPayload;
                      try {
                        final decoded = jsonDecode(controller.currentJsonText);
                        if (decoded is Map<String, dynamic>) {
                          draftPayload = decoded;
                        }
                      } catch (_) {}

                      ProfileReleaseDiffDialog.show(
                        context,
                        titleA: 'Release v$ver ($state)',
                        payloadA: profile,
                        titleB: 'Current Local Draft (${defId ?? "draft"})',
                        payloadB: draftPayload,
                      );
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note, size: 14),
                    label: Text('Create Next Draft (v${ver + 1})',
                        style: const TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ProfileLabTheme.primaryAccent,
                      side: const BorderSide(
                          color: ProfileLabTheme.primaryAccent),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                    onPressed: () {
                      final defId =
                          (profile['profileDefinitionId'] as String?) ??
                              (release['profileDefinitionId'] as String?);
                      if (defId != null) {
                        controller.createDraftFromRelease(
                          profileDefinitionId: defId,
                          releasePayload: profile,
                        );
                      }
                    },
                  ),
                  if (state == 'testing') ...[
                    ElevatedButton.icon(
                      icon: const Icon(Icons.arrow_upward, size: 14),
                      label: const Text('Promote to Beta',
                          style: TextStyle(fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ProfileLabTheme.primaryAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                      ),
                      onPressed: onPromote,
                    ),
                  ],
                  if (state == 'beta') ...[
                    const Tooltip(
                      message:
                          'Stable promotion requires qualifying Cloud evidence.',
                      child: Chip(
                        avatar: Icon(Icons.cloud_done_outlined, size: 14),
                        label: Text('Requires Cloud evidence'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                  if (state != 'revoked') ...[
                    OutlinedButton.icon(
                      icon: const Icon(Icons.block, size: 14),
                      label: const Text('Revoke Release...',
                          style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ProfileLabTheme.failColor,
                        side:
                            const BorderSide(color: ProfileLabTheme.failColor),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      onPressed: onRevoke,
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  _PropertyRow(
                      label: 'Lifecycle State', value: state.toUpperCase()),
                  if (state == 'revoked')
                    _PropertyRow(
                      label: 'Revocation Reason',
                      value: (release['lifecycleReason'] as String?) ??
                          'Security / Compliance Action',
                    ),
                  _PropertyRow(label: 'Publisher', value: publisher),
                  _PropertyRow(label: 'Signing Key ID', value: signingKey),
                  _PropertyRow(label: 'Published At', value: publishedAt),
                  _PropertyRow(
                      label: 'Payload Digest',
                      value: digest,
                      isMonospace: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('CANONICAL IMMUTABLE PAYLOAD JSON',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8))),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ProfileLabTheme.darkBackground,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: SelectableText(
              formattedJson,
              style: const TextStyle(
                  fontFamily: 'Menlo', fontSize: 11, color: Color(0xFFCBD5E1)),
            ),
          ),
        ],
      ),
    );
  }
}

class _LifecycleBadge extends StatelessWidget {
  const _LifecycleBadge({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'stable' => ProfileLabTheme.passColor,
      'beta' => Colors.purpleAccent,
      'testing' => Colors.blueAccent,
      'retired' => Colors.orangeAccent,
      'revoked' => ProfileLabTheme.failColor,
      _ => const Color(0xFF94A3B8),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        state.toUpperCase(),
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: isMonospace ? 'Menlo' : null,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
