import 'dart:convert';
import 'package:flutter/material.dart';

import '../theme/profile_lab_theme.dart';
import '../utils/profile_domain_diff.dart';

/// Interactive domain-based Tool Profile Release Diff viewer and modal dialog.
class ProfileReleaseDiffDialog extends StatefulWidget {
  const ProfileReleaseDiffDialog({
    super.key,
    required this.titleA,
    required this.payloadA,
    required this.titleB,
    required this.payloadB,
  });

  final String titleA;
  final Map<String, dynamic>? payloadA;
  final String titleB;
  final Map<String, dynamic>? payloadB;

  static void show(
    BuildContext context, {
    required String titleA,
    required Map<String, dynamic>? payloadA,
    required String titleB,
    required Map<String, dynamic>? payloadB,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => ProfileReleaseDiffDialog(
        titleA: titleA,
        payloadA: payloadA,
        titleB: titleB,
        payloadB: payloadB,
      ),
    );
  }

  @override
  State<ProfileReleaseDiffDialog> createState() =>
      _ProfileReleaseDiffDialogState();
}

class _ProfileReleaseDiffDialogState extends State<ProfileReleaseDiffDialog> {
  bool _onlyChanged = true;
  int _viewMode = 0; // 0: Domain Diff Cards, 1: Raw JSON Split

  @override
  Widget build(BuildContext context) {
    final diffGroups = ProfileDomainDiffCalculator.computeDiff(
        widget.payloadA, widget.payloadB);
    final totalChanges =
        diffGroups.fold<int>(0, (sum, g) => sum + g.changeCount);

    const encoder = JsonEncoder.withIndent('  ');
    final jsonA = encoder.convert(widget.payloadA ?? {});
    final jsonB = encoder.convert(widget.payloadB ?? {});

    return Dialog(
      child: Container(
        width: 960,
        height: 640,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Toolbar Header
            Row(
              children: [
                const Icon(Icons.compare,
                    color: ProfileLabTheme.primaryAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Profile Domain Diff — ${widget.titleA} vs ${widget.titleB}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: totalChanges > 0
                        ? ProfileLabTheme.warnColor.withValues(alpha: 0.2)
                        : ProfileLabTheme.passColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    totalChanges > 0
                        ? '$totalChanges domain changes'
                        : 'Identical payloads',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: totalChanges > 0
                          ? ProfileLabTheme.warnColor
                          : ProfileLabTheme.passColor,
                    ),
                  ),
                ),
                const Spacer(),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        label: Text('Domain Cards',
                            style: TextStyle(fontSize: 11))),
                    ButtonSegment(
                        value: 1,
                        label: Text('Raw JSON Split',
                            style: TextStyle(fontSize: 11))),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (set) =>
                      setState(() => _viewMode = set.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_viewMode == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('Show Changed Domains Only',
                          style: TextStyle(fontSize: 11)),
                      selected: _onlyChanged,
                      onSelected: (val) => setState(() => _onlyChanged = val),
                    ),
                  ],
                ),
              ),

            // Content Body
            Expanded(
              child: _viewMode == 0
                  ? ListView(
                      children: diffGroups
                          .where((g) => !_onlyChanged || g.hasChanges)
                          .map((g) => _DomainDiffGroupCard(
                              group: g,
                              titleA: widget.titleA,
                              titleB: widget.titleB))
                          .toList(),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                color: ProfileLabTheme.darkSurface,
                                width: double.infinity,
                                child: Text(widget.titleA.toUpperCase(),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amber)),
                              ),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  color: ProfileLabTheme.darkBackground,
                                  child: SingleChildScrollView(
                                    child: SelectableText(jsonA,
                                        style: ProfileLabTheme.monoStyle
                                            .copyWith(fontSize: 11)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const VerticalDivider(
                            width: 1, color: Color(0xFF334155)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                color: ProfileLabTheme.darkSurface,
                                width: double.infinity,
                                child: Text(widget.titleB.toUpperCase(),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: ProfileLabTheme.primaryAccent)),
                              ),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  color: ProfileLabTheme.darkBackground,
                                  child: SingleChildScrollView(
                                    child: SelectableText(jsonB,
                                        style: ProfileLabTheme.monoStyle
                                            .copyWith(fontSize: 11)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DomainDiffGroupCard extends StatelessWidget {
  const _DomainDiffGroupCard({
    required this.group,
    required this.titleA,
    required this.titleB,
  });

  final DomainDiffGroup group;
  final String titleA;
  final String titleB;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: group.hasChanges
              ? ProfileLabTheme.warnColor.withValues(alpha: 0.6)
              : const Color(0xFF334155),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: group.hasChanges
                  ? ProfileLabTheme.warnColor.withValues(alpha: 0.1)
                  : const Color(0xFF1E293B),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(5)),
            ),
            child: Row(
              children: [
                Icon(group.icon,
                    size: 16,
                    color: group.hasChanges
                        ? ProfileLabTheme.warnColor
                        : const Color(0xFF94A3B8)),
                const SizedBox(width: 8),
                Text(
                  group.domainName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: group.hasChanges
                        ? Colors.white
                        : const Color(0xFF94A3B8),
                  ),
                ),
                const Spacer(),
                if (group.hasChanges)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.warnColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${group.changeCount} change(s)',
                      style: const TextStyle(
                          fontSize: 11,
                          color: ProfileLabTheme.warnColor,
                          fontWeight: FontWeight.bold),
                    ),
                  )
                else
                  const Text('No changes',
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: group.items
                  .map((item) => _DomainDiffItemRow(
                      item: item, titleA: titleA, titleB: titleB))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _DomainDiffItemRow extends StatelessWidget {
  const _DomainDiffItemRow({
    required this.item,
    required this.titleA,
    required this.titleB,
  });

  final DomainDiffItem item;
  final String titleA;
  final String titleB;

  @override
  Widget build(BuildContext context) {
    Color badgeColor;
    String badgeText;
    switch (item.changeType) {
      case DiffChangeType.added:
        badgeColor = ProfileLabTheme.passColor;
        badgeText = 'ADDED';
        break;
      case DiffChangeType.removed:
        badgeColor = ProfileLabTheme.failColor;
        badgeText = 'REMOVED';
        break;
      case DiffChangeType.modified:
        badgeColor = ProfileLabTheme.warnColor;
        badgeText = 'MODIFIED';
        break;
      case DiffChangeType.unchanged:
        badgeColor = const Color(0xFF64748B);
        badgeText = 'UNCHANGED';
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkBackground,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: item.changeType != DiffChangeType.unchanged
                ? badgeColor.withValues(alpha: 0.4)
                : Colors.transparent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(item.fieldLabel,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFE2E8F0))),
              const SizedBox(width: 8),
              Text('(${item.fieldPath})',
                  style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11,
                      color: Color(0xFF64748B))),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(badgeText,
                    style: TextStyle(
                        fontSize: 11,
                        color: badgeColor,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (item.changeType != DiffChangeType.unchanged) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color:
                              ProfileLabTheme.failColor.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '$titleA:\n${item.valueA ?? "<none>"}',
                      style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 11,
                          color: Color(0xFFFCA5A5)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward,
                    size: 14, color: Color(0xFF64748B)),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color:
                              ProfileLabTheme.passColor.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      '$titleB:\n${item.valueB ?? "<none>"}',
                      style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 11,
                          color: Color(0xFF86EFAC)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
