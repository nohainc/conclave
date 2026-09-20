enum RunStatus { running, paused, completed, failed, cancelled }

enum TaskStatus { completed, running, ready, blocked, pending }

enum FindingSeverity { blocker, major, minor, note }

enum FindingStatus { open, fixed, verified }

class StudioProject {
  const StudioProject({
    required this.id,
    required this.name,
    required this.repository,
    required this.branch,
    required this.activeGoals,
    required this.lastActivity,
  });

  final String id;
  final String name;
  final String repository;
  final String branch;
  final int activeGoals;
  final String lastActivity;
}

class StudioWorker {
  const StudioWorker({
    required this.id,
    required this.name,
    required this.provider,
    required this.role,
    required this.capabilities,
    required this.status,
    required this.cost,
  });

  final String id;
  final String name;
  final String provider;
  final String role;
  final List<String> capabilities;
  final String status;
  final String cost;
}

class StudioTask {
  const StudioTask({
    required this.id,
    required this.title,
    required this.phase,
    required this.status,
    required this.worker,
    required this.detail,
    required this.progress,
    required this.dependencies,
    required this.tokens,
    required this.cost,
  });

  final String id;
  final String title;
  final String phase;
  final TaskStatus status;
  final String worker;
  final String detail;
  final double progress;
  final List<String> dependencies;
  final String tokens;
  final String cost;
}

class StudioFinding {
  const StudioFinding({
    required this.id,
    required this.title,
    required this.description,
    required this.severity,
    required this.status,
    required this.taskId,
    required this.author,
  });

  final String id;
  final String title;
  final String description;
  final FindingSeverity severity;
  final FindingStatus status;
  final String taskId;
  final String author;
}

class StudioEvent {
  const StudioEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.kind,
  });

  final String time;
  final String title;
  final String detail;
  final String kind;
}

class StudioArtifact {
  const StudioArtifact({
    required this.name,
    required this.type,
    required this.size,
    required this.source,
  });

  final String name;
  final String type;
  final String size;
  final String source;
}

class StudioModelCall {
  const StudioModelCall({
    required this.worker,
    required this.model,
    required this.task,
    required this.tokens,
    required this.cost,
    required this.duration,
    required this.status,
  });

  final String worker;
  final String model;
  final String task;
  final String tokens;
  final String cost;
  final String duration;
  final String status;
}

class StudioSnapshot {
  const StudioSnapshot({
    required this.projects,
    required this.workers,
    required this.tasks,
    required this.findings,
    required this.events,
    required this.artifacts,
    required this.modelCalls,
  });

  final List<StudioProject> projects;
  final List<StudioWorker> workers;
  final List<StudioTask> tasks;
  final List<StudioFinding> findings;
  final List<StudioEvent> events;
  final List<StudioArtifact> artifacts;
  final List<StudioModelCall> modelCalls;

  static StudioSnapshot demo() => const StudioSnapshot(
        projects: [
          StudioProject(
            id: 'forge',
            name: 'Forge',
            repository: 'nohainc/conclave',
            branch: 'main',
            activeGoals: 1,
            lastActivity: '2 min ago',
          ),
          StudioProject(
            id: 'atlas',
            name: 'Atlas API',
            repository: 'nohainc/atlas-api',
            branch: 'develop',
            activeGoals: 0,
            lastActivity: 'Yesterday',
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
      );
}
