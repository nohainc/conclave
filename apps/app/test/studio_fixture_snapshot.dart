import 'package:conclave_app/src/studio/studio_models.dart';

StudioSnapshot studioFixtureSnapshot() => const StudioSnapshot(
      activeRunId: 'run-fixture',
      run: StudioRun(
        id: 'run-fixture',
        status: RunStatus.running,
        objective: 'Improve authentication architecture',
        taskCount: 4,
        completedTaskCount: 1,
        openFindingCount: 1,
        verifiedCriterionCount: 0,
        criterionCount: 2,
      ),
      projects: [
        StudioProject(
          id: 'forge',
          name: 'Forge',
          branch: 'main',
          lastActivity: '2 min ago',
          workstreams: [
            StudioWorkstream(
              id: 'workstream-auth',
              projectId: 'forge',
              name: 'Authentication hardening',
              lead: 'Vitalii',
              status: 'active',
              brief:
                  'Harden the authentication boundaries before the next release.',
              primaryWorkspace: 'MacBook Pro',
              currentCheckpoint: 'Repository review',
              queueStatus: 'Idle',
            ),
          ],
        ),
        StudioProject(
          id: 'atlas',
          name: 'Atlas API',
          branch: 'develop',
          lastActivity: 'Yesterday',
        ),
      ],
      workspaces: [
        StudioWorkspace(
          id: 'workspace-macbook',
          name: 'Development Workspace',
          hostname: 'development-agent.local',
          status: 'ONLINE',
          appVersion: '1.5.0',
          workerCount: 5,
          activeTaskCount: 1,
        ),
      ],
      tasks: [
        StudioTask(
          id: 'research',
          title: 'Research repository structure',
          phase: 'Understand',
          status: TaskStatus.completed,
          worker: 'Lead',
          detail:
              'Mapped app boundaries and identified the Flutter entry point.',
          progress: 1,
          dependencies: [],
        ),
        StudioTask(
          id: 'implement',
          title: 'Build the Studio execution surface',
          phase: 'Build',
          status: TaskStatus.running,
          worker: 'Lead',
          detail: 'Implementing the first usable run dashboard and controls.',
          progress: .68,
          dependencies: ['Research repository structure'],
        ),
        StudioTask(
          id: 'review',
          title: 'Review implementation independently',
          phase: 'Verify',
          status: TaskStatus.ready,
          worker: 'Reviewer',
          detail:
              'Waiting for implementation output before starting isolated review.',
          progress: 0,
          dependencies: ['Build the Studio execution surface'],
        ),
        StudioTask(
          id: 'tests',
          title: 'Run Flutter and TypeScript checks',
          phase: 'Verify',
          status: TaskStatus.pending,
          worker: 'Local Runtime',
          detail:
              'Will collect executable evidence for the completion criteria.',
          progress: 0,
          dependencies: ['Build the Studio execution surface'],
        ),
      ],
      findings: [
        StudioFinding(
          id: 'F-104',
          title: 'Add persistence adapter boundary',
          description:
              'The dashboard currently uses a local snapshot; connect this surface to the run aggregate before production use.',
          severity: FindingSeverity.major,
          status: FindingStatus.open,
          taskId: 'implement',
          author: 'Reviewer',
        ),
        StudioFinding(
          id: 'F-098',
          title: 'Show empty state for projects',
          description:
              'Projects without active goals need a clear next action.',
          severity: FindingSeverity.minor,
          status: FindingStatus.verified,
          taskId: 'research',
          author: 'Reviewer',
        ),
      ],
      events: [
        StudioEvent(
            time: '09:42',
            title: 'Task started',
            detail: 'Build the Studio execution surface · Lead',
            kind: 'task'),
        StudioEvent(
            time: '09:41',
            title: 'Plan accepted',
            detail: '4 tasks across 3 phases',
            kind: 'plan'),
        StudioEvent(
            time: '09:40',
            title: 'Goal created',
            detail: 'Build a useful Conclave Studio UI',
            kind: 'goal'),
        StudioEvent(
            time: '09:40',
            title: 'Worker selected',
            detail: 'Lead resolved with implementation capability',
            kind: 'worker'),
      ],
      artifacts: [
        StudioArtifact(
            name: 'repository-map.md',
            type: 'Research report',
            size: '12 KB',
            source: 'Lead · Research'),
        StudioArtifact(
            name: 'studio-preview.png',
            type: 'Screenshot',
            size: '184 KB',
            source: 'Local Runtime · Build'),
        StudioArtifact(
            name: 'plan.json',
            type: 'Structured plan',
            size: '4 KB',
            source: 'Lead · Plan'),
      ],
      candidateOutputs: [
        StudioCandidateOutput(
          worker: 'Lead',
          role: 'researcher',
          status: 'Complete',
          summary: 'Mapped repository boundaries and Flutter entry points.',
          artifactCount: 3,
        ),
        StudioCandidateOutput(
          worker: 'Reviewer',
          role: 'architect',
          status: 'Complete',
          summary: 'Identified the API boundary and persistence handoff.',
          artifactCount: 2,
        ),
      ],
      synthesisDecision: StudioSynthesisDecision(
        status: 'Accepted',
        summary: 'Both candidates agree on the next implementation boundary.',
        worker: 'Lead · Synthesizer',
        evidence: 'DecisionResult · 2 candidate outputs',
      ),
    );
