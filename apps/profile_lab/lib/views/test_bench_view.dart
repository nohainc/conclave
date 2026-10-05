import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';
import '../theme/profile_lab_theme.dart';
import 'ai_repair_loop_dialog.dart';

/// Testing and local acceptance evidence belong to the active Draft.
class TestBenchView extends StatelessWidget {
  const TestBenchView({super.key, required this.controller});
  final ProfileLabController controller;

  Future<void> _perform(
      BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: CopyableMessage('Could not complete action: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final draft = c.currentDraft;
    if (draft == null) {
      return const Center(
          child: Text('Create an initial draft to start testing.'));
    }
    final tool = draft.profile['providerTool'] as Map;
    final provider = tool['name'] as String;
    final candidates =
        (tool['executableCandidates'] as List).whereType<String>();
    String? path;
    for (final executable in candidates) {
      path ??= c.detectedProviderPaths[executable];
    }
    final stages = c.testResultMatchesDraft
        ? c.activeLadderStages
        : <ProfileLabLadderStageResult>[];
    ProfileLabLadderStageResult? stage(String id) {
      for (final item in stages) {
        if (item.stageId == id) return item;
      }
      return null;
    }

    final discovery = stage('executable_discovery');
    final versionStage = stage('cli_version');
    final authentication = stage('passive_probe');
    final version = versionStage?.details['cliVersion'] as String? ??
        versionStage?.details['detectedProviderVersion'] as String?;
    final running = c.isTesting && c.testResultMatchesDraft;
    final completed =
        !running && c.testResultMatchesDraft && c.lastTestResult != null;
    final busy = c.isTesting || c.isPublishing || c.isSavingToCloud;
    final canRun = !busy && !c.isDirty && c.jsonValidationError == null;
    final passed = stages.where((s) => s.status == 'passed').length;
    final skipped = stages.where((s) => s.status == 'skipped').length;
    final failed = stages.where((s) => s.status == 'failed').toList();
    Map<String, Object?>? evidence;
    for (final item in c.currentEvidence) {
      if (item['profileDefinitionId'] == draft.profileDefinitionId &&
          item['releaseVersion'] == draft.releaseVersion &&
          item['profileDigest'] == draft.payloadDigest &&
          ToolProfileAcceptanceEvidence.hasCloudContractShape(item,
              profile: draft.profile)) {
        evidence = item;
        break;
      }
    }
    final qualified = evidence != null &&
        !c.isDirty &&
        !running &&
        (!completed || c.lastTestResult == 'pass');
    final elapsed = c.lastLadderResult != null && c.testResultMatchesDraft
        ? c.lastLadderResult!.endedAt.difference(c.lastLadderResult!.startedAt)
        : c.testCompletedAt != null && c.testStartedAt != null
            ? c.testCompletedAt!.difference(c.testStartedAt!)
            : null;
    final savedAcceptance = evidence != null && !c.testResultMatchesDraft;
    final resultVersion = version ??
        (completed || running
            ? null
            : evidence?['providerToolVersion'] as String?) ??
        'Version not observed';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Profile Tests',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 12),
        _PreflightRow(
            label: 'Provider CLI',
            value: discovery == null
                ? (path == null ? 'Not found' : 'Found')
                : discovery.status == 'passed'
                    ? 'Found'
                    : discovery.status == 'failed'
                        ? 'Unavailable'
                        : 'Not checked',
            passed: discovery == null
                ? (path != null ? true : null)
                : _passed(discovery),
            detail: provider),
        _PreflightRow(
            label: 'Version',
            value: versionStage == null || versionStage.status == 'skipped'
                ? (savedAcceptance
                    ? '$resultVersion · Last tested'
                    : 'Not checked')
                : versionStage.status == 'passed'
                    ? '$version · Supported'
                    : '${version ?? "Probe failed"} · Needs attention',
            passed: savedAcceptance ? true : _passed(versionStage),
            detail: versionStage?.diagnostics),
        _PreflightRow(
            label: 'Authentication',
            value: authentication == null || authentication.status == 'skipped'
                ? (savedAcceptance
                    ? 'Profile checks previously passed'
                    : 'Not checked')
                : authentication.status == 'passed'
                    ? 'Ready · Profile checks passed'
                    : 'Needs attention',
            passed: savedAcceptance ? true : _passed(authentication),
            detail: authentication?.diagnostics),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: Text(running ? 'Running…' : 'Run Full Test'),
              onPressed: canRun ? () => c.runTestLadder() : null),
          if (c.isTesting)
            OutlinedButton(
                onPressed: c.cancelTest, child: const Text('Cancel')),
        ]),
        if (c.isTesting && !running)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'A test is running for another Draft. Cancel it or wait to start this Draft’s test.')),
        if (c.isDirty || c.jsonValidationError != null)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Save a valid Draft before testing.')),
        if (!running && !completed && evidence == null)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Version and authentication are checked during the full test.')),
        if (running) ...[
          const SizedBox(height: 16),
          OperationProgress(
              label: 'Running Profile tests…', value: stages.length / 11),
          const SizedBox(height: 8),
          Text(c.testStatusMessage ?? 'Running full test…'),
          const SizedBox(height: 8),
          for (final item in stages) _StageResult(stage: item),
        ],
        if (completed || evidence != null && !running) ...[
          const SizedBox(height: 16),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            completed
                                ? '$passed/11 passed${skipped > 0 ? " · $skipped skipped" : ""}'
                                : 'Saved local acceptance evidence',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                        const SizedBox(height: 6),
                        Text('$provider · $resultVersion'),
                        if (completed)
                          Text(
                              'Duration: ${elapsed == null ? "Unavailable" : "${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s"}'),
                        const SizedBox(height: 8),
                        Text(
                            qualified
                                ? 'Ready for Cloud qualification'
                                : c.isDirty
                                    ? 'Draft modified · Save and rerun to qualify'
                                    : 'Not qualified · Full test required',
                            style: TextStyle(
                                color: qualified
                                    ? ProfileLabTheme.passColor
                                    : ProfileLabTheme.warnColor)),
                        if (completed &&
                            c.lastTestResult == 'fail' &&
                            failed.isEmpty)
                          Text(c.testStatusMessage ?? 'Full test failed.'),
                      ]))),
          if (qualified && !c.canPublish)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(c.labAccess?.releaseManager != true
                    ? 'Release Manager access is required to publish.'
                    : 'Cloud Profile signing is not ready. Configure the signer and refresh access.')),
          if (qualified &&
              c.cloudReleaseLifecycleState != null &&
              c.cloudReleaseLifecycleState != 'draft')
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: const Text('View Releases'),
                    onPressed: () =>
                        c.setWorkerSubView(WorkerSubView.releases))),
          if (qualified &&
              (c.cloudReleaseLifecycleState == null ||
                  c.cloudReleaseLifecycleState == 'draft'))
            Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: Text(
                        c.isPublishing ? 'Publishing…' : 'Publish to Testing'),
                    onPressed: !c.canPublish ||
                            busy ||
                            c.cloudDraftExists != true ||
                            c.cloudDigest != draft.payloadDigest ||
                            c.isDirty
                        ? null
                        : () => _perform(context, c.publishCurrentDraft))),
          if (qualified && c.canPublish && c.cloudReleaseLifecycleState == null)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Sync this Draft to Cloud before publishing.')),
          if (completed && c.lastTestResult == 'fail') ...[
            for (final item in failed)
              _StageResult(
                  stage: item, actions: _failureActions(context, item, canRun)),
            if (failed.isEmpty)
              Wrap(
                  spacing: 8, children: _failureActions(context, null, canRun)),
          ],
          if (stages.isNotEmpty)
            ExpansionTile(
                key: ValueKey('test-stages-${draft.payloadDigest}'),
                title: const Text('Test stages'),
                children: [
                  for (final item in stages) _StageResult(stage: item)
                ]),
          if (evidence != null)
            ExpansionTile(
                key: ValueKey('local-evidence-${draft.payloadDigest}'),
                title: const Text('Local acceptance evidence'),
                subtitle: const Text(
                    'Saved for this exact Draft · Cloud validates on publication'),
                children: [
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                          const JsonEncoder.withIndent('  ').convert(evidence),
                          style: ProfileLabTheme.monoStyle))
                ]),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
            key: ValueKey('execution-details-${draft.payloadDigest}'),
            title: Row(children: [
              const Expanded(child: Text('Execution details')),
              if (c.testResultMatchesDraft && c.testLogs.isNotEmpty)
                CopyMessageButton(
                    tooltip: 'Copy execution details',
                    message: c.testLogs
                        .map((log) =>
                            '${log.timestamp.toIso8601String()} ${log.level.toUpperCase()} · ${log.message}')
                        .join('\n'))
            ]),
            subtitle: Text(
                '${c.testResultMatchesDraft ? c.testLogs.length : 0} streamed events'),
            children: [
              SizedBox(
                  height: 240,
                  child: c.testLogs.isEmpty || !c.testResultMatchesDraft
                      ? const Center(
                          child: Text('Execution logs appear during a run.'))
                      : ListView.builder(
                          itemCount: c.testLogs.length,
                          itemBuilder: (_, index) {
                            final log = c.testLogs[index];
                            return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 3),
                                child: CopyableMessage(
                                    '${log.timestamp.toIso8601String().substring(11, 19)} ${log.level.toUpperCase()} · ${log.message}',
                                    style: ProfileLabTheme.monoStyle.copyWith(
                                        color: log.level == 'error'
                                            ? ProfileLabTheme.failColor
                                            : null)));
                          }))
            ]),
      ]),
    );
  }

  static bool? _passed(ProfileLabLadderStageResult? stage) =>
      stage?.status == 'passed'
          ? true
          : stage?.status == 'failed'
              ? false
              : null;

  List<Widget> _failureActions(
      BuildContext context, ProfileLabLadderStageResult? stage, bool enabled) {
    final c = controller;
    final min = stage?.details['suggestedMin'];
    final max = stage?.details['suggestedMaxExclusive'];
    return [
      OutlinedButton(
          onPressed: enabled ? () => c.runTestLadder() : null,
          child: const Text('Retry')),
      if (stage?.stageId == 'cli_version' && min is String && max is String)
        OutlinedButton(
            onPressed: enabled
                ? () => _perform(
                    context,
                    () => c.applyRecommendedProviderCompatibilityRange(
                        min: min, maxExclusive: max))
                : null,
            child: const Text('Apply version range')),
      OutlinedButton.icon(
          icon: const Icon(Icons.auto_awesome, size: 16),
          onPressed: enabled ? () => AiRepairLoopDialog.show(context, c) : null,
          label: const Text('Repair Profile')),
    ];
  }
}

class _PreflightRow extends StatelessWidget {
  const _PreflightRow(
      {required this.label, required this.value, this.passed, this.detail});
  final String label;
  final String value;
  final bool? passed;
  final String? detail;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            passed == true
                ? Icons.check_circle_outline
                : passed == false
                    ? Icons.error_outline
                    : Icons.radio_button_unchecked,
            size: 18,
            color: passed == true
                ? ProfileLabTheme.passColor
                : passed == false
                    ? ProfileLabTheme.failColor
                    : const Color(0xFF94A3B8)),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Tooltip(
              message: detail ?? value,
              child: Text(value, style: const TextStyle(fontSize: 12))),
        ])),
      ]));
}

class _StageResult extends StatelessWidget {
  const _StageResult({required this.stage, this.actions = const []});
  final ProfileLabLadderStageResult stage;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            stage.status == 'passed'
                ? Icons.check_circle_outline
                : stage.status == 'failed'
                    ? Icons.error_outline
                    : Icons.remove_circle_outline,
            size: 18,
            color: stage.status == 'failed'
                ? ProfileLabTheme.failColor
                : stage.status == 'passed'
                    ? ProfileLabTheme.passColor
                    : const Color(0xFF94A3B8)),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${stage.displayName} · ${stage.status}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          CopyableMessage(
              '${stage.displayName} · ${stage.status}\n${stage.diagnostics}',
              style: const TextStyle(fontSize: 12)),
          if (actions.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 4, children: actions),
        ])),
      ]));
}
