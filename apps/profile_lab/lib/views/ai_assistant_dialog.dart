import '../widgets/lab_components.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/ai_provenance.dart';
import '../utils/profile_ai_assistant.dart';
import '../utils/profile_domain_diff.dart';
import '../utils/profile_lab_model_proposals.dart';

class AiAssistantDialog extends StatefulWidget {
  const AiAssistantDialog({super.key, required this.controller});

  final ProfileLabController controller;

  static Future<void> show(
      BuildContext context, ProfileLabController controller) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AiAssistantDialog(controller: controller),
    );
  }

  @override
  State<AiAssistantDialog> createState() => _AiAssistantDialogState();
}

class _AiAssistantDialogState extends State<AiAssistantDialog> {
  final _instructionCtrl = TextEditingController(
    text:
        'Review the current Draft and recent test diagnostics. Suggest a minimal safe improvement.',
  );
  final _contextBuilder = const ProfileAiAssistantContextBuilder();

  late AiAssistantContext _context;
  List<ProfileLabAiModelOption> _models = [];
  String? _selectedModelId;
  String? _generationError;
  bool _loadingModels = true;
  bool _shareContextConfirmed = false;
  Map<String, dynamic>? _proposedPayload;
  List<DomainDiffGroup> _proposedDiffs = [];
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _context = _contextBuilder.gatherContext(widget.controller);
    unawaited(_loadModels());
  }

  @override
  void dispose() {
    if (_isGenerating) {
      unawaited(widget.controller.cancelAiDraftProposal());
    }
    _instructionCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final models = await widget.controller.loadAvailableAiModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _selectedModelId = models.firstOrNull?.id;
        _generationError =
            models.isEmpty ? widget.controller.aiProposalError : null;
        _loadingModels = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generationError = error.toString();
        _loadingModels = false;
      });
    }
  }

  Future<void> _generateProposal() async {
    final modelId = _selectedModelId;
    if (modelId == null) return;
    setState(() {
      _isGenerating = true;
      _generationError = null;
      _proposedPayload = null;
      _proposedDiffs = [];
    });
    try {
      final proposed = await widget.controller.generateAiDraftProposal(
        modelOptionId: modelId,
        userInstruction: _instructionCtrl.text.trim(),
        dataSharingConfirmed: _shareContextConfirmed,
      );
      final diffs = ProfileDomainDiffCalculator.computeDiff(
        _context.currentDraft,
        proposed,
      );
      if (!mounted) return;
      setState(() {
        _proposedPayload = proposed;
        _proposedDiffs = diffs;
      });
    } catch (error) {
      if (mounted) setState(() => _generationError = error.toString());
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.auto_awesome,
              color: ProfileLabTheme.primaryAccent, size: 22),
          SizedBox(width: 8),
          Expanded(child: Text('AI Profile Draft Proposal')),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ProfileLabTheme.warnColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ProfileLabTheme.warnColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.science_outlined,
                        color: ProfileLabTheme.warnColor, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'A signed Stable Worker Profile runs through the local generic Engine. The model proposes a Draft edit only. Review the diff, apply it yourself, and run the real test ladder; model output is never evidence.',
                        style: TextStyle(
                            fontSize: 11, color: ProfileLabTheme.darkForeground),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Ingested Context Badges Box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ProfileLabTheme.darkBackground,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ProfileLabTheme.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'INGESTED CONTEXT BOUNDARY (SAFE / NON-CREDENTIAL)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: ProfileLabTheme.primaryAccent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildContextChip(
                            'Worker: ${_context.workerMetadata['workerTypeId']}',
                            Icons.engineering),
                        _buildContextChip(
                          'Stable Profile: ${_context.stableProfile != null ? "Ingested" : "None"}',
                          Icons.verified,
                        ),
                        _buildContextChip(
                            'Draft Payload: v${c.currentDraft?.releaseVersion ?? 1}',
                            Icons.description),
                        _buildContextChip(
                            'Test Diagnostics: ${_context.testDiagnostics.length} items',
                            Icons.fact_check),
                        _buildContextChip(
                            'Provider CLI Info: Ingested', Icons.terminal),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              const Text('Model Profile:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (_loadingModels)
                const LinearProgressIndicator(minHeight: 2)
              else if (_models.isEmpty)
                Text(
                  _generationError ??
                      'No trusted Stable Worker Profile is available.',
                  style: const TextStyle(
                      fontSize: 11, color: ProfileLabTheme.warnColor),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _selectedModelId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: _models
                      .map((model) => DropdownMenuItem<String>(
                            value: model.id,
                            child: Text(model.label,
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: _isGenerating
                      ? null
                      : (value) => setState(() => _selectedModelId = value),
                ),
              const SizedBox(height: 12),

              const Text('Draft change request:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              TextField(
                controller: _instructionCtrl,
                maxLines: 2,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText:
                      'Describe desired profile updates or targeted fix...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _shareContextConfirmed,
                onChanged: _isGenerating
                    ? null
                    : (value) =>
                        setState(() => _shareContextConfirmed = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'I agree to send this Draft and its bounded test diagnostics to the selected provider.',
                  style: TextStyle(fontSize: 11),
                ),
                subtitle: const Text(
                  'Provider authentication stays in its locally installed CLI. Profile Lab does not store provider credentials.',
                  style: TextStyle(
                      fontSize: 11, color: ProfileLabTheme.secondaryText),
                ),
              ),
              const SizedBox(height: 6),

              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _isGenerating ||
                            _loadingModels ||
                            _selectedModelId == null ||
                            !_shareContextConfirmed
                        ? null
                        : _generateProposal,
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome, size: 16),
                    label: Text(_isGenerating
                        ? 'Generating with Model…'
                        : 'Generate Draft Proposal'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ProfileLabTheme.primaryAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_isGenerating)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: widget.controller.cancelAiDraftProposal,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Cancel model request'),
                  ),
                ),
              if (_generationError != null &&
                  !_loadingModels &&
                  _models.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _generationError!,
                    style:
                        const TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
                ),

              if (_proposedPayload != null) ...[
                const Divider(color: ProfileLabTheme.borderColor),
                const SizedBox(height: 8),
                const Text('PROPOSED DOMAIN DIFF PREVIEW:',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: ProfileLabTheme.secondaryText)),
                const SizedBox(height: 8),

                if (!_proposedDiffs.any((g) => g.hasChanges))
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('No structural domain changes proposed.',
                        style: TextStyle(
                            fontSize: 12,
                            color: ProfileLabTheme.secondaryText)),
                  )
                else
                  Column(
                    children:
                        _proposedDiffs.where((g) => g.hasChanges).map((group) {
                      final changedItems = group.items
                          .where(
                              (i) => i.changeType != DiffChangeType.unchanged)
                          .toList();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: ProfileLabTheme.darkSurface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: ProfileLabTheme.warnColor
                                  .withValues(alpha: 0.3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(group.icon,
                                    size: 14, color: ProfileLabTheme.warnColor),
                                const SizedBox(width: 6),
                                Text(
                                  group.domainName,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: ProfileLabTheme.warnColor),
                                ),
                                const Spacer(),
                                Text(
                                  '${group.changeCount} change${group.changeCount > 1 ? "s" : ""}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: ProfileLabTheme.secondaryText),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ...changedItems.map((item) => Padding(
                                  padding:
                                      const EdgeInsets.only(left: 8, bottom: 4),
                                  child: Text(
                                    '${item.fieldLabel} (${item.fieldPath}): ${item.valueA ?? "null"} → ${item.valueB ?? "null"}',
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white),
                                  ),
                                )),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                const SizedBox(height: 12),

                // Strict Safety Boundary Banner
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ProfileLabTheme.darkSurface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: ProfileLabTheme.borderColor),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          color: ProfileLabTheme.passColor, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Human review required: Applying only updates the local Draft editor. Publication remains a separate human action that requires successful local qualification and Cloud signer preflight. Stable promotion requires separate Cloud acceptance evidence.',
                          style: TextStyle(
                              fontSize: 11,
                              color: ProfileLabTheme.secondaryText,
                              height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _proposedPayload == null
              ? null
              : () {
                  final selectedModel = _models.firstWhere(
                    (model) => model.id == _selectedModelId,
                  );
                  final provenance = AiProvenance(
                    authorType: 'ai_assistant',
                    modelIdentifier: selectedModel.modelIdentifier,
                    parentDigest: c.currentDraft?.payloadDigest,
                    parentReleaseVersion: c.currentDraft?.releaseVersion,
                    taskIdentifier: _instructionCtrl.text.trim(),
                    diffDigest: AiProvenance.computeDiffDigest(_proposedDiffs),
                    reviewedBy: c.currentSession?.displayName,
                    actor: c.currentSession?.displayName,
                  );
                  c.applyAiDraftProposal(
                    profile: Map<String, dynamic>.from(_proposedPayload!),
                    provenance: provenance.toJson(),
                  );
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: CopyableMessage(
                            'Reviewed model proposal applied to the local Draft.')),
                  );
                },
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Review & Apply to Draft'),
          style: ElevatedButton.styleFrom(
            backgroundColor: ProfileLabTheme.passColor,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildContextChip(String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: ProfileLabTheme.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ProfileLabTheme.primaryAccent),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.white)),
        ],
      ),
    );
  }
}
