import '../widgets/lab_components.dart';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../bundled_cli_worker_engine_loader.dart';
import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/ai_provenance.dart';
import '../utils/profile_ai_repair_loop.dart';
import '../utils/profile_domain_diff.dart';

class AiRepairLoopDialog extends StatefulWidget {
  const AiRepairLoopDialog({super.key, required this.controller});

  final ProfileLabController controller;

  static Future<void> show(
      BuildContext context, ProfileLabController controller) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AiRepairLoopDialog(controller: controller),
    );
  }

  @override
  State<AiRepairLoopDialog> createState() => _AiRepairLoopDialogState();
}

class _AiRepairLoopDialogState extends State<AiRepairLoopDialog> {
  final _runner = ProfileAiRepairLoopRunner();

  int _maxIterations = 3;
  int _currentIteration = 0;
  bool _isRunning = false;
  String _statusText = 'Ready to start iterative AI repair loop.';

  Map<String, dynamic>? _workingPayload;
  final List<RepairIterationRecord> _history = [];
  RepairIterationRecord? _currentRecord;
  bool _loopCompleted = false;
  bool _loopSuccess = false;

  bool get isLoopCompleted => _loopCompleted;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c.currentDraft != null) {
      _workingPayload = Map<String, dynamic>.from(c.currentDraft!.profile);
    }
  }

  Future<void> _startRepairLoop() async {
    if (_workingPayload == null) return;

    setState(() {
      _isRunning = true;
      _currentIteration = 1;
      _history.clear();
      _loopCompleted = false;
      _loopSuccess = false;
      _statusText = 'Starting Iteration 1 of $_maxIterations...';
    });

    await _executeIteration(1, _workingPayload!);
  }

  Future<void> _executeIteration(int iter, Map<String, dynamic> payload) async {
    setState(() {
      _statusText =
          'Iteration $iter/$_maxIterations: Validating & Running Progressive Test Ladder...';
    });

    try {
      final c = widget.controller;
      c.engineExecutable ??= await loadBundledCliWorkerEngine(
          enginesDirectory: c.paths.enginesDirectory);
      if (c.engineExecutable == null) {
        throw StateError('Generic CLI Worker Engine binary is not available.');
      }

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: c.paths.sandboxDirectory,
        engineExecutable: c.engineExecutable!,
      );

      final record = await _runner.runIteration(
        controller: c,
        iterationNumber: iter,
        workingPayload: payload,
        sandbox: sandbox,
      );

      setState(() {
        _currentRecord = record;
        _history.add(record);

        if (record.status == RepairIterationStep.completed) {
          _isRunning = false;
          _loopCompleted = true;
          _loopSuccess = true;
          _statusText =
              'Repair successful! All Progressive Test Ladder stages passed cleanly.';
        } else if (iter >= _maxIterations) {
          _isRunning = false;
          _loopCompleted = true;
          _loopSuccess = false;
          _statusText =
              'Reached maximum iteration limit ($_maxIterations). Review latest proposed candidate.';
        } else {
          _isRunning = false;
          _statusText =
              'Iteration $iter finished. Human confirmation required to apply revision and retest.';
        }
      });
    } catch (e) {
      setState(() {
        _isRunning = false;
        _statusText = 'Repair loop error: $e';
      });
    }
  }

  Future<void> _applyAndRetestNext() async {
    if (_currentRecord?.aiProposedPayload == null) return;

    final proposed = _currentRecord!.aiProposedPayload!;
    _currentRecord!.applied = true;
    _workingPayload = proposed;
    final nextIter = _currentIteration + 1;

    setState(() {
      _currentIteration = nextIter;
      _isRunning = true;
    });

    await _executeIteration(nextIter, proposed);
  }

  void _applyFinalToDraft() {
    final rawPayload = _currentRecord?.aiProposedPayload ?? _workingPayload;
    if (rawPayload == null) return;

    final c = widget.controller;
    final provenance = AiProvenance(
      authorType: 'ai_repair_loop',
      modelIdentifier: 'experimental-local-heuristic',
      parentDigest: c.currentDraft?.payloadDigest,
      parentReleaseVersion: c.currentDraft?.releaseVersion,
      taskIdentifier: 'repair-loop-iter-$_currentIteration',
      diffDigest: _currentRecord != null
          ? AiProvenance.computeDiffDigest(_currentRecord!.diffGroups)
          : null,
      reviewedBy: c.currentSession?.displayName ?? 'Vitalii',
      actor: c.currentSession?.displayName ?? 'Vitalii',
    );

    final payload = Map<String, dynamic>.from(rawPayload);
    payload['_provenance'] = provenance.toJson();

    const encoder = JsonEncoder.withIndent('  ');
    final jsonText = encoder.convert(payload);
    c.updateJsonText(jsonText);

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: CopyableMessage(
              'Repaired candidate proposal with provenance applied to local Draft.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = _currentRecord;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.build_circle_outlined,
              color: ProfileLabTheme.primaryAccent, size: 22),
          SizedBox(width: 8),
          Text('Experimental Heuristic Profile Repair Loop'),
        ],
      ),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.amber),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.science_outlined, color: Colors.amber, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Experimental local heuristic. No AI model is called; suggestions need human review and real tests, and never count as acceptance evidence.',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Strategy Stepper / Information Box
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
                      'REPAIR WORKFLOW LADDER',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: ProfileLabTheme.primaryAccent,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Candidate → Validate & Test Ladder → Normalize Failures → AI Revision → Domain Diff → Retest',
                      style: TextStyle(fontSize: 11, color: Color(0xFFE2E8F0)),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text('Max Automatic Iterations:',
                            style: TextStyle(
                                fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: _maxIterations,
                          isDense: true,
                          dropdownColor: ProfileLabTheme.darkSurface,
                          items: [1, 2, 3, 4, 5].map((val) {
                            return DropdownMenuItem<int>(
                              value: val,
                              child: Text('$val iterations',
                                  style: const TextStyle(fontSize: 11)),
                            );
                          }).toList(),
                          onChanged: _isRunning
                              ? null
                              : (val) {
                                  if (val != null) {
                                    setState(() => _maxIterations = val);
                                  }
                                },
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: _isRunning || _loopSuccess
                              ? null
                              : _startRepairLoop,
                          icon: _isRunning
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.play_arrow, size: 16),
                          label: Text(_history.isEmpty
                              ? 'Start Repair Loop'
                              : 'Restart Loop'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ProfileLabTheme.primaryAccent,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Status Bar
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: ProfileLabTheme.darkSurface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: _loopSuccess
                        ? ProfileLabTheme.passColor
                        : _isRunning
                            ? ProfileLabTheme.primaryAccent
                            : const Color(0xFF334155),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _loopSuccess
                          ? Icons.check_circle
                          : _isRunning
                              ? Icons.autorenew
                              : Icons.info_outline,
                      size: 16,
                      color: _loopSuccess
                          ? ProfileLabTheme.passColor
                          : _isRunning
                              ? ProfileLabTheme.primaryAccent
                              : const Color(0xFF94A3B8),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: _loopSuccess
                              ? ProfileLabTheme.passColor
                              : Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Iteration History & Normalized Failures Display
              if (_history.isNotEmpty) ...[
                const Text('REPAIR ITERATION HISTORY:',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF94A3B8))),
                const SizedBox(height: 6),
                Column(
                  children:
                      _history.map((h) => _buildIterationCard(h)).toList(),
                ),
                const SizedBox(height: 12),
              ],

              // Latest Domain Diff Preview
              if (record != null && record.aiProposedPayload != null) ...[
                const Text('REVISED DOMAIN DIFF PREVIEW:',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF94A3B8))),
                const SizedBox(height: 6),
                _buildDiffPreview(record.diffGroups),
                const SizedBox(height: 12),
              ],

              // Safety Policy Banner
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
                        'Human Authority Safeguard: AI operates strictly inside the local repair loop sandbox. AI cannot publish, sign, or promote releases. Material draft changes require human confirmation.',
                        style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                            height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (record != null &&
            record.aiProposedPayload != null &&
            !_loopSuccess &&
            _currentIteration < _maxIterations)
          ElevatedButton.icon(
            onPressed: _isRunning ? null : _applyAndRetestNext,
            icon: const Icon(Icons.sync, size: 16),
            label: Text(
                'Apply Revision & Retest Iteration ${_currentIteration + 1}'),
            style: ElevatedButton.styleFrom(
              backgroundColor: ProfileLabTheme.warnColor,
              foregroundColor: Colors.white,
            ),
          ),
        ElevatedButton.icon(
          onPressed: record == null ||
                  (record.aiProposedPayload == null && !_loopSuccess)
              ? null
              : _applyFinalToDraft,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Apply Candidate to Local Draft'),
          style: ElevatedButton.styleFrom(
            backgroundColor: ProfileLabTheme.passColor,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildIterationCard(RepairIterationRecord h) {
    final isLatest = h.iterationNumber == _currentIteration;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isLatest
              ? ProfileLabTheme.primaryAccent
              : const Color(0xFF334155),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Iteration ${h.iterationNumber}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: h.ladderResult?.overallResult == 'pass'
                      ? ProfileLabTheme.passColor.withValues(alpha: 0.2)
                      : ProfileLabTheme.failColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  h.ladderResult?.overallResult.toUpperCase() ?? 'TESTING',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: h.ladderResult?.overallResult == 'pass'
                        ? ProfileLabTheme.passColor
                        : ProfileLabTheme.failColor,
                  ),
                ),
              ),
              const Spacer(),
              if (h.applied)
                const Text('Revision Applied',
                    style: TextStyle(
                        fontSize: 11, color: ProfileLabTheme.passColor)),
            ],
          ),
          if (h.normalizedFailures.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text('Normalized Failures:',
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: h.normalizedFailures.map((f) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF450A0A),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color:
                            ProfileLabTheme.failColor.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '${f['displayName']}: ${f['issueCode']}',
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5)),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDiffPreview(List<DomainDiffGroup> diffs) {
    final changed = diffs.where((g) => g.hasChanges).toList();
    if (changed.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: ProfileLabTheme.darkSurface,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text('No structural domain changes proposed.',
            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
      );
    }

    return Column(
      children: changed.map((g) {
        final changedItems = g.items
            .where((i) => i.changeType != DiffChangeType.unchanged)
            .toList();
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: ProfileLabTheme.warnColor.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(g.icon, size: 14, color: ProfileLabTheme.warnColor),
                  const SizedBox(width: 6),
                  Text(g.domainName,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: ProfileLabTheme.warnColor)),
                  const Spacer(),
                  Text('${g.changeCount} change(s)',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF94A3B8))),
                ],
              ),
              const SizedBox(height: 4),
              ...changedItems.map((item) => Text(
                    ' • ${item.fieldLabel}: ${item.valueA ?? "null"} → ${item.valueB ?? "null"}',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  )),
            ],
          ),
        );
      }).toList(),
    );
  }
}
