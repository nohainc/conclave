import 'dart:convert';
import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

import 'profile_release_diff_view.dart';

/// Schema-aware Tool Profile v1 Draft Editor with live validation,
/// structured summary panels, compare, revert, and duplicate options.
class ProfileDraftEditor extends StatefulWidget {
  const ProfileDraftEditor(
      {super.key, required this.controller, this.showInspector = false});

  final ProfileLabController controller;
  final bool showInspector;

  @override
  State<ProfileDraftEditor> createState() => _ProfileDraftEditorState();
}

class _ProfileDraftEditorState extends State<ProfileDraftEditor> {
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController =
        TextEditingController(text: widget.controller.currentJsonText);
  }

  @override
  void didUpdateWidget(ProfileDraftEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_textController.text != widget.controller.currentJsonText) {
      _textController.text = widget.controller.currentJsonText;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return Row(
      children: [
        // Main Editor Surface
        Expanded(
          child: c.currentDraft == null
              ? const Center(
                  child: Text('Select or create a draft to begin authoring.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))))
              : LayoutBuilder(
                  builder: (context, layout) => Column(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                                maxHeight: layout.maxHeight * 0.4),
                            child: SingleChildScrollView(
                                child: Column(children: [
                              // Conflict Banner
                              if (c.syncState == DraftSyncState.conflict)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: ProfileLabTheme.failColor
                                        .withValues(alpha: 0.15),
                                    border: const Border(
                                        bottom: BorderSide(
                                            color: ProfileLabTheme.failColor)),
                                  ),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Icon(Icons.warning_amber_rounded,
                                          color: ProfileLabTheme.failColor,
                                          size: 18),
                                      const SizedBox(width: 8),
                                      const SizedBox(
                                        width: 260,
                                        child: Text(
                                          'CONFLICT DETECTED: Local edits conflict with updated Cloud draft payload.',
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: ProfileLabTheme.failColor),
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        icon: const Icon(Icons.compare_arrows,
                                            size: 14),
                                        label: const Text(
                                            'Compare Local vs Cloud',
                                            style: TextStyle(fontSize: 11)),
                                        onPressed: () {
                                          Map<String, dynamic>? draftPayload;
                                          try {
                                            final decoded =
                                                jsonDecode(c.currentJsonText);
                                            if (decoded
                                                is Map<String, dynamic>) {
                                              draftPayload = decoded;
                                            }
                                          } catch (_) {}
                                          ProfileReleaseDiffDialog.show(
                                            context,
                                            titleA:
                                                'Local Draft (${c.selectedDefinitionId})',
                                            payloadA: draftPayload,
                                            titleB: 'Cloud Draft (Concurrent)',
                                            payloadB: c.cloudDraftPayload,
                                          );
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                ProfileLabTheme.failColor),
                                        onPressed: () =>
                                            c.resolveConflictKeepLocal(),
                                        child: const Text(
                                            'Overwrite Cloud Draft',
                                            style: TextStyle(fontSize: 11)),
                                      ),
                                      const SizedBox(width: 6),
                                      OutlinedButton(
                                        onPressed: () =>
                                            c.resolveConflictKeepCloud(),
                                        child: const Text('Discard Local Edits',
                                            style: TextStyle(fontSize: 11)),
                                      ),
                                    ],
                                  ),
                                ),

                              // Cloud Changed Banner
                              if (c.syncState == DraftSyncState.cloudChanged)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: ProfileLabTheme.primaryAccent
                                        .withValues(alpha: 0.15),
                                    border: const Border(
                                        bottom: BorderSide(
                                            color:
                                                ProfileLabTheme.primaryAccent)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.cloud_download,
                                          color: ProfileLabTheme.primaryAccent,
                                          size: 18),
                                      const SizedBox(width: 8),
                                      const Expanded(
                                        child: Text(
                                          'CLOUD UPDATED: A newer draft version is available on Cloud.',
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: ProfileLabTheme
                                                  .primaryAccent),
                                        ),
                                      ),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                ProfileLabTheme.primaryAccent),
                                        onPressed: () =>
                                            c.resolveConflictKeepCloud(),
                                        child: const Text('Load Cloud Version',
                                            style: TextStyle(fontSize: 11)),
                                      ),
                                    ],
                                  ),
                                ),

                              // Continuous Validation Diagnostics Banner
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: c.jsonValidationError == null
                                      ? ProfileLabTheme.passColor
                                          .withValues(alpha: 0.12)
                                      : ProfileLabTheme.failColor
                                          .withValues(alpha: 0.15),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: c.jsonValidationError == null
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      c.jsonValidationError == null
                                          ? Icons.check_circle_outline
                                          : Icons.error_outline,
                                      color: c.jsonValidationError == null
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        c.jsonValidationError == null
                                            ? 'Valid Tool Profile v1 Schema'
                                            : 'Validation Error: ${c.jsonValidationError}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: c.jsonValidationError == null
                                              ? ProfileLabTheme.passColor
                                              : ProfileLabTheme.failColor,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ])),
                          ),
                          Expanded(
                            child:
                                LayoutBuilder(builder: (context, constraints) {
                              final editor = Container(
                                key: const ValueKey('profile-json-editor'),
                                color: ProfileLabTheme.darkBackground,
                                padding: const EdgeInsets.all(12),
                                child: TextField(
                                  controller: _textController,
                                  maxLines: null,
                                  expands: true,
                                  style: ProfileLabTheme.monoStyle
                                      .copyWith(fontSize: 12),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                    hintText: 'Tool Profile JSON',
                                  ),
                                  onChanged: c.updateJsonText,
                                ),
                              );
                              if (!widget.showInspector) return editor;
                              final inspector =
                                  _StructuredSummaryPanel(controller: c);
                              return constraints.maxWidth >= 680
                                  ? Row(children: [
                                      Expanded(child: editor),
                                      const VerticalDivider(width: 1),
                                      SizedBox(width: 280, child: inspector)
                                    ])
                                  : Column(children: [
                                      Expanded(child: editor),
                                      const Divider(height: 1),
                                      Expanded(child: inspector)
                                    ]);
                            }),
                          ),
                        ],
                      )),
        ),
      ],
    );
  }
}

/// Structured Summary Panel rendering live parsed fields from the draft JSON payload.
class _StructuredSummaryPanel extends StatelessWidget {
  const _StructuredSummaryPanel({required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? parsedJson;
    try {
      final decoded = jsonDecode(controller.currentJsonText);
      if (decoded is Map<String, dynamic>) {
        parsedJson = decoded;
      }
    } catch (_) {}

    if (parsedJson == null || controller.jsonValidationError != null) {
      return Container(
        color: ProfileLabTheme.darkSurface,
        padding: const EdgeInsets.all(16),
        child: const Center(
          child: Text(
            'Fix Profile validation errors to view the Inspector.',
            style: TextStyle(fontSize: 11, color: ProfileLabTheme.failColor),
          ),
        ),
      );
    }

    final providerTool =
        parsedJson['providerTool'] as Map<String, dynamic>? ?? {};
    final candidates =
        (providerTool['executableCandidates'] as List?)?.cast<String>() ?? [];
    final discovery = providerTool['discovery'] as Map<String, dynamic>? ?? {};
    final env = parsedJson['environment'] as Map<String, dynamic>? ?? {};
    final capabilities =
        (parsedJson['capabilities'] as List?)?.cast<String>() ?? [];
    final sandbox = parsedJson['sandbox'] as Map<String, dynamic>? ?? {};

    return Container(
      color: ProfileLabTheme.darkSurface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('Inspector',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8))),
          const SizedBox(height: 8),

          // Identity Card
          _SummaryCard(
            title: 'Profile Identity',
            icon: Icons.badge,
            children: [
              _SummaryRow(
                  label: 'Definition ID',
                  value:
                      parsedJson['profileDefinitionId']?.toString() ?? 'n/a'),
              _SummaryRow(
                  label: 'Worker Type ID',
                  value:
                      parsedJson['logicalWorkerTypeId']?.toString() ?? 'n/a'),
              _SummaryRow(
                  label: 'Release Version',
                  value: 'v${parsedJson['releaseVersion']}'),
              _SummaryRow(
                  label: 'Engine Family',
                  value: parsedJson['engineFamily']?.toString() ?? 'n/a'),
              _SummaryRow(
                  label: 'Saved digest',
                  value: controller.currentDraft?.payloadDigest ?? 'n/a'),
            ],
          ),
          const SizedBox(height: 10),

          // Provider Tool Card
          _SummaryCard(
            title: 'Provider Tool Identity',
            icon: Icons.terminal,
            children: [
              _SummaryRow(
                  label: 'Tool Name',
                  value: providerTool['name']?.toString() ?? 'n/a'),
              _SummaryRow(label: 'Executables', value: candidates.join(', ')),
              _SummaryRow(
                  label: 'PATH Search',
                  value: (discovery['allowPathSearch'] ?? false).toString()),
            ],
          ),
          const SizedBox(height: 10),

          // Capabilities Card
          _SummaryCard(
            title: 'Capabilities & Scope',
            icon: Icons.star_outline,
            children: [
              _SummaryRow(
                  label: 'Capabilities',
                  value:
                      capabilities.isEmpty ? 'none' : capabilities.join(', ')),
            ],
          ),
          const SizedBox(height: 10),

          // Environment & Security Card
          _SummaryCard(
            title: 'Environment & Sandbox',
            icon: Icons.security,
            children: [
              _SummaryRow(
                  label: 'Pass-Through Env',
                  value: ((env['passthrough'] as List?)?.join(', ')) ?? 'none'),
              _SummaryRow(
                  label: 'Sandbox modes',
                  value:
                      (sandbox['mappings'] as Map?)?.keys.join(', ') ?? 'none'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: ProfileLabTheme.primaryAccent),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white))),
            ],
          ),
          const Divider(height: 12, color: Color(0xFF334155)),
          ...children,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: ConclaveTypography.monoSmall
                  .copyWith(color: const Color(0xFFE2E8F0)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
