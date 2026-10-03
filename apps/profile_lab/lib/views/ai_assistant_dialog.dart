import 'dart:convert';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/ai_provenance.dart';
import '../utils/profile_ai_assistant.dart';
import '../utils/profile_domain_diff.dart';

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
        'Analyze passive probe and execution arguments, then propose an updated Tool Profile candidate.',
  );
  final _assistantService = const ProfileAiAssistantService();

  late AiAssistantContext _context;
  Map<String, dynamic>? _proposedPayload;
  List<DomainDiffGroup> _proposedDiffs = [];
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _context = _assistantService.gatherContext(widget.controller);
  }

  @override
  void dispose() {
    _instructionCtrl.dispose();
    super.dispose();
  }

  void _generateProposal() {
    setState(() => _isGenerating = true);

    final proposed = _assistantService.proposeCandidateDraft(
      context: _context,
      userInstruction: _instructionCtrl.text.trim(),
    );

    final diffs = ProfileDomainDiffCalculator.computeDiff(
        _context.currentDraft, proposed);

    setState(() {
      _proposedPayload = proposed;
      _proposedDiffs = diffs;
      _isGenerating = false;
    });
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
          Text('AI Profile Candidate Assistant'),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ingested Context Badges Box
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'INGESTED CONTEXT BOUNDARY (SAFE / NON-CREDENTIAL)',
                      style: TextStyle(
                        fontSize: 10,
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

              const Text('AI Generation Prompt / Target Goal:',
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

              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _isGenerating ? null : _generateProposal,
                    icon: _isGenerating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('Generate Candidate Proposal'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ProfileLabTheme.primaryAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_proposedPayload != null) ...[
                const Divider(color: Color(0xFF334155)),
                const SizedBox(height: 8),
                const Text('PROPOSED DOMAIN DIFF PREVIEW:',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF94A3B8))),
                const SizedBox(height: 8),

                if (!_proposedDiffs.any((g) => g.hasChanges))
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('No structural domain changes proposed.',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
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
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: ProfileLabTheme.darkSurface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: ProfileLabTheme.warnColor
                                  .withValues(alpha: 0.4)),
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
                                      fontSize: 10, color: Color(0xFF94A3B8)),
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
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          color: ProfileLabTheme.passColor, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Safety Policy: AI proposals always land in local Draft. AI cannot publish, Ed25519 sign, promote Stable, or alter evidence. You must test and promote via promotion gates.',
                          style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
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
                  final provenance = AiProvenance(
                    authorType: 'ai_assistant',
                    modelIdentifier: 'gemini-2.5-pro',
                    parentDigest: c.currentDraft?.payloadDigest,
                    parentReleaseVersion: c.currentDraft?.releaseVersion,
                    taskIdentifier: _instructionCtrl.text.trim(),
                    diffDigest: AiProvenance.computeDiffDigest(_proposedDiffs),
                    reviewedBy: c.currentSession?.displayName ?? 'Vitalii',
                    actor: c.currentSession?.displayName ?? 'Vitalii',
                  );
                  final payloadToSave =
                      Map<String, dynamic>.from(_proposedPayload!);
                  payloadToSave['_provenance'] = provenance.toJson();

                  final encoder = const JsonEncoder.withIndent('  ');
                  final jsonText = encoder.convert(payloadToSave);
                  c.updateJsonText(jsonText);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'AI candidate proposal with provenance applied to local Draft.')),
                  );
                },
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Apply Proposal to Draft'),
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
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: ProfileLabTheme.primaryAccent),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Color(0xFFE2E8F0))),
        ],
      ),
    );
  }
}
