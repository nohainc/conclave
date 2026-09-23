import 'package:conclave_app/src/studio/studio_models.dart';

StudioSnapshot studioFixtureSnapshot() => const StudioSnapshot(
      activeRunId: 'run-fixture',
      activeChatId: 'chat-auth-1',
      run: StudioRun(
        id: 'run-fixture',
        status: RunStatus.running,
        objective: 'Improve authentication architecture',
        taskCount: 4,
        completedTaskCount: 1,
        openFindingCount: 1,
        verifiedCriterionCount: 0,
        criterionCount: 2,
        tokens: 32500,
        costMicros: 650000,
      ),
      projects: [
        StudioProject(
          id: 'forge',
          name: 'Forge',
          repository: 'nohainc/conclave',
          branch: 'main',
          activeGoals: 1,
          lastActivity: '2 min ago',
          chats: [
            StudioChat(
              id: 'chat-auth-1',
              projectId: 'forge',
              title: 'Improve authentication architecture',
              lastActivity: 'Just now',
              activeRunId: 'run-fixture',
              messages: [
                StudioChatMessage(
                  id: 'msg-user-1',
                  sender: StudioMessageSender.user,
                  text: 'Improve authentication architecture.',
                  timestamp: '10:14 AM',
                ),
                StudioChatMessage(
                  id: 'msg-conclave-1',
                  sender: StudioMessageSender.conclave,
                  text:
                      'Researching repository boundaries and coordinating candidate workers across GPT-4o and Claude 3.7.',
                  timestamp: '10:15 AM',
                  runPreview: StudioRunPreview(
                    runId: 'run-fixture',
                    statusSummary: 'Researching with 2 Workers...',
                    phases: [
                      StudioPhaseItem(
                        name: 'Research',
                        status: StudioPhaseStatus.completed,
                        detail:
                            'Repository boundaries and auth endpoints identified',
                      ),
                      StudioPhaseItem(
                        name: 'Synthesis',
                        status: StudioPhaseStatus.inProgress,
                        detail:
                            'Consolidating PKCE token rotation and session limits',
                      ),
                      StudioPhaseItem(
                        name: 'Implementation',
                        status: StudioPhaseStatus.pending,
                        detail: 'Worker code patch generation',
                      ),
                    ],
                    workerCount: 2,
                    finalAnswer:
                        '### Architecture Recommendation\n\n1. **PKCE Authentication Flow**: Migrate all client sessions to short-lived scoped JWTs with client-bound ephemeral proofs.\n2. **Multi-Agent Consensus Gate**: Require cryptographic signature checks across independent reviewer workers before tenant admin role elevations.\n3. **Distributed Revocation List**: Store blacklisted tokens in edge KV memory with automatic 15-minute TTL expirations.',
                  ),
                ),
              ],
            ),
            StudioChat(
              id: 'chat-stream-2',
              projectId: 'forge',
              title: 'Streaming assignment protocol',
              lastActivity: '1 hour ago',
              messages: [
                StudioChatMessage(
                  id: 'msg-stream-u1',
                  sender: StudioMessageSender.user,
                  text:
                      'How should worker assignment progress chunks stream to Cloud?',
                  timestamp: '09:00 AM',
                ),
                StudioChatMessage(
                  id: 'msg-stream-c1',
                  sender: StudioMessageSender.conclave,
                  text:
                      'Progress chunks are transmitted over the persistent AgentGateway DO WebSocket connection with incremental percentage and stage logs.',
                  timestamp: '09:01 AM',
                ),
              ],
            ),
          ],
        ),
        StudioProject(
          id: 'atlas',
          name: 'Atlas API',
          repository: 'nohainc/atlas-api',
          branch: 'develop',
          activeGoals: 0,
          lastActivity: 'Yesterday',
          chats: [
            StudioChat(
              id: 'chat-db-1',
              projectId: 'atlas',
              title: 'Database migration v2',
              lastActivity: 'Yesterday',
              messages: [
                StudioChatMessage(
                  id: 'msg-db-u1',
                  sender: StudioMessageSender.user,
                  text:
                      'Plan zero-downtime D1 migration for event sourcing ledger.',
                  timestamp: 'Yesterday',
                ),
                StudioChatMessage(
                  id: 'msg-db-c1',
                  sender: StudioMessageSender.conclave,
                  text:
                      'Migration plan formulated: step 1 shadow writes, step 2 backfill verification, step 3 read-switchover.',
                  timestamp: 'Yesterday',
                ),
              ],
            ),
          ],
        ),
      ],
      workers: [
        StudioWorker(
          id: 'lead',
          name: 'Lead',
          provider: 'OpenAI',
          role: 'lead',
          capabilities: ['planning', 'implementation', 'evaluation'],
          status: 'Available',
          cost: '\$0.02 / 1k tokens',
        ),
        StudioWorker(
          id: 'reviewer',
          name: 'Reviewer',
          provider: 'Anthropic',
          role: 'reviewer',
          capabilities: ['code_review', 'risk_analysis'],
          status: 'Working',
          cost: '\$0.03 / 1k tokens',
        ),
        StudioWorker(
          id: 'runtime',
          name: 'Local Runtime',
          provider: 'Conclave',
          role: 'executor',
          capabilities: ['tests', 'git', 'artifacts'],
          status: 'Connected',
          cost: 'Local',
        ),
      ],
      accounts: [
        StudioCredentialProfile(
          id: 'account-codex',
          displayName: 'Vitalii Codex',
          owner: 'Vitalii',
          worker: 'Codex',
          host: 'Development Host',
          sharing: 'Private',
          status: 'ready',
          usage: '12.4k tokens · \$2.10 this month',
        ),
      ],
      agents: [
        StudioAgent(
          id: 'agent-macbook',
          name: 'Development Host',
          hostname: 'development-agent.local',
          status: 'ONLINE',
          version: '1.5.0',
          pluginCount: 3,
          workerCount: 5,
          activeTaskCount: 1,
          desiredWorkers: [
            StudioDesiredWorker(workerId: 'codex', version: '1.2.0'),
            StudioDesiredWorker(workerId: 'claude-code', version: '1.0.4'),
          ],
          installedWorkers: [
            StudioInstalledWorker(
                workerId: 'codex', version: '1.2.0', status: 'ready'),
            StudioInstalledWorker(
                workerId: 'claude-code', version: '1.0.4', status: 'ready'),
          ],
        ),
      ],
      plugins: [
        StudioPlugin(
            id: 'codex',
            name: 'Codex',
            version: '1.2.0',
            status: 'Installed',
            roles: ['Implementation', 'Research'],
            capabilities: ['repository_write', 'tests']),
        StudioPlugin(
            id: 'claude-code',
            name: 'Claude Code',
            version: '1.0.4',
            status: 'Installed',
            roles: ['Review', 'Research'],
            capabilities: ['code_review', 'repository_read']),
        StudioPlugin(
            id: 'openai',
            name: 'OpenAI',
            version: 'API',
            status: 'Available',
            roles: ['Planning'],
            capabilities: ['planning']),
        StudioPlugin(
            id: 'anthropic',
            name: 'Anthropic',
            version: 'API',
            status: 'Available',
            roles: ['Review'],
            capabilities: ['code_review']),
        StudioPlugin(
            id: 'git',
            name: 'Git',
            version: 'builtin',
            status: 'Installed',
            roles: ['Tool'],
            capabilities: ['git', 'diff']),
        StudioPlugin(
            id: 'docker',
            name: 'Docker',
            version: 'builtin',
            status: 'Available',
            roles: ['Tool'],
            capabilities: ['build', 'sandbox']),
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
          tokens: '8.4k',
          cost: '\$0.17',
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
          tokens: '24.1k',
          cost: '\$0.48',
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
          tokens: '—',
          cost: '—',
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
          tokens: '—',
          cost: '—',
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
      modelCalls: [
        StudioModelCall(
            worker: 'Lead',
            model: 'gpt-5.6-sol',
            task: 'Build the Studio execution surface',
            tokens: '24.1k',
            cost: '\$0.48',
            duration: '1m 42s',
            status: 'Streaming'),
        StudioModelCall(
            worker: 'Lead',
            model: 'gpt-5.6-sol',
            task: 'Research repository structure',
            tokens: '8.4k',
            cost: '\$0.17',
            duration: '38s',
            status: 'Complete'),
      ],
      policy: StudioPolicy(
        preset: StudioQualityPreset.balanced,
        mode: 'parallel',
        candidateCount: 2,
        maxParallel: 2,
        costCeiling: '\$0.04 / attempt',
        requiresSynthesis: true,
      ),
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
