import 'dart:convert';
import 'package:flutter/material.dart';

enum DiffChangeType { added, removed, modified, unchanged }

class DomainDiffItem {
  const DomainDiffItem({
    required this.fieldLabel,
    required this.fieldPath,
    required this.valueA,
    required this.valueB,
    required this.changeType,
  });

  final String fieldLabel;
  final String fieldPath;
  final String? valueA;
  final String? valueB;
  final DiffChangeType changeType;
}

class DomainDiffGroup {
  const DomainDiffGroup({
    required this.domainName,
    required this.icon,
    required this.items,
  });

  final String domainName;
  final IconData icon;
  final List<DomainDiffItem> items;

  bool get hasChanges =>
      items.any((item) => item.changeType != DiffChangeType.unchanged);
  int get changeCount =>
      items.where((item) => item.changeType != DiffChangeType.unchanged).length;
}

class ProfileDomainDiffCalculator {
  static List<DomainDiffGroup> computeDiff(
      Map<String, dynamic>? a, Map<String, dynamic>? b) {
    final payloadA = a ?? {};
    final payloadB = b ?? {};

    return [
      _diffProviderTool(payloadA, payloadB),
      _diffExecution(payloadA, payloadB),
      _diffEnvironment(payloadA, payloadB),
      _diffPassiveProbe(payloadA, payloadB),
      _diffSession(payloadA, payloadB),
      _diffModel(payloadA, payloadB),
      _diffSandbox(payloadA, payloadB),
      _diffTimeout(payloadA, payloadB),
      _diffProgress(payloadA, payloadB),
      _diffErrorMappings(payloadA, payloadB),
      _diffCapabilities(payloadA, payloadB),
    ];
  }

  static DomainDiffGroup _diffProviderTool(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final toolA = (a['providerTool'] as Map<String, dynamic>?) ?? {};
    final toolB = (b['providerTool'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Tool Name',
        'providerTool.name',
        toolA['name']?.toString(),
        toolB['name']?.toString(),
      ),
      _compareField(
        'Executable Candidates',
        'providerTool.executableCandidates',
        _formatJson(toolA['executableCandidates']),
        _formatJson(toolB['executableCandidates']),
      ),
      _compareField(
        'PATH Search Allowed',
        'providerTool.discovery.allowPathSearch',
        (toolA['discovery'] as Map?)?['allowPathSearch']?.toString(),
        (toolB['discovery'] as Map?)?['allowPathSearch']?.toString(),
      ),
      _compareField(
        'Version Probe',
        'providerTool.versionProbe',
        _formatJson(toolA['versionProbe']),
        _formatJson(toolB['versionProbe']),
      ),
      _compareField(
        'Supported Versions',
        'providerTool.supportedVersions',
        _formatJson(toolA['supportedVersions']),
        _formatJson(toolB['supportedVersions']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Provider Tool & Discovery',
      icon: Icons.terminal,
      items: items,
    );
  }

  static DomainDiffGroup _diffExecution(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final execA = (a['execution'] as Map<String, dynamic>?) ?? {};
    final execB = (b['execution'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Command Arguments',
        'execution.arguments',
        _formatJson(execA['arguments']),
        _formatJson(execB['arguments']),
      ),
      _compareField(
        'Stdin Mode',
        'execution.stdin',
        _formatJson(execA['stdin']),
        _formatJson(execB['stdin']),
      ),
      _compareField(
        'Output Mode',
        'execution.output',
        _formatJson(execA['output']),
        _formatJson(execB['output']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Execution Arguments & I/O',
      icon: Icons.play_arrow_outlined,
      items: items,
    );
  }

  static DomainDiffGroup _diffEnvironment(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final envA = (a['environment'] as Map<String, dynamic>?) ?? {};
    final envB = (b['environment'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Passthrough Env Vars',
        'environment.passthrough',
        _formatJson(envA['passthrough']),
        _formatJson(envB['passthrough']),
      ),
      _compareField(
        'Environment Set Map',
        'environment.set',
        _formatJson(envA['set']),
        _formatJson(envB['set']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Environment Variables',
      icon: Icons.tune,
      items: items,
    );
  }

  static DomainDiffGroup _diffPassiveProbe(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final probeA = (a['probe'] as Map<String, dynamic>?) ?? {};
    final probeB = (b['probe'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Passive Probes',
        'probe.passive',
        _formatJson(probeA['passive']),
        _formatJson(probeB['passive']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Passive Readiness Probes',
      icon: Icons.fact_check_outlined,
      items: items,
    );
  }

  static DomainDiffGroup _diffSession(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final sessA = (a['session'] as Map<String, dynamic>?) ?? {};
    final sessB = (b['session'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Session Support',
        'session.supported',
        sessA['supported']?.toString(),
        sessB['supported']?.toString(),
      ),
      _compareField(
        'Format ID',
        'session.formatId',
        sessA['formatId']?.toString(),
        sessB['formatId']?.toString(),
      ),
      _compareField(
        'Resume Arguments',
        'session.resumeArguments',
        _formatJson(sessA['resumeArguments']),
        _formatJson(sessB['resumeArguments']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Session Persistence',
      icon: Icons.history,
      items: items,
    );
  }

  static DomainDiffGroup _diffModel(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final modelA = (a['model'] as Map<String, dynamic>?) ?? {};
    final modelB = (b['model'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Model Support',
        'model.supported',
        modelA['supported']?.toString(),
        modelB['supported']?.toString(),
      ),
      _compareField(
        'Model Arguments',
        'model.arguments',
        _formatJson(modelA['arguments']),
        _formatJson(modelB['arguments']),
      ),
      _compareField(
        'Unknown Model Policy',
        'model.unknownModelPolicy',
        modelA['unknownModelPolicy']?.toString(),
        modelB['unknownModelPolicy']?.toString(),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'AI Model Configuration',
      icon: Icons.psychology_outlined,
      items: items,
    );
  }

  static DomainDiffGroup _diffSandbox(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final sbA = (a['sandbox'] as Map<String, dynamic>?) ?? {};
    final sbB = (b['sandbox'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Sandbox Mappings',
        'sandbox.mappings',
        _formatJson(sbA['mappings']),
        _formatJson(sbB['mappings']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Sandbox & Security Boundaries',
      icon: Icons.security,
      items: items,
    );
  }

  static DomainDiffGroup _diffTimeout(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final timeA = (a['timeout'] as Map<String, dynamic>?) ?? {};
    final timeB = (b['timeout'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Provider Arguments',
        'timeout.providerArguments',
        _formatJson(timeA['providerArguments']),
        _formatJson(timeB['providerArguments']),
      ),
      _compareField(
        'Reserve Buffer (Ms)',
        'timeout.providerReserveMs',
        timeA['providerReserveMs']?.toString(),
        timeB['providerReserveMs']?.toString(),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Timeouts & Reserve Margins',
      icon: Icons.timer_outlined,
      items: items,
    );
  }

  static DomainDiffGroup _diffProgress(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final items = <DomainDiffItem>[
      _compareField(
        'Progress Strategy',
        'progress',
        _formatJson(a['progress']),
        _formatJson(b['progress']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Progress Monitoring',
      icon: Icons.pending_actions,
      items: items,
    );
  }

  static DomainDiffGroup _diffErrorMappings(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final errA = (a['errors'] as Map<String, dynamic>?) ?? {};
    final errB = (b['errors'] as Map<String, dynamic>?) ?? {};

    final items = <DomainDiffItem>[
      _compareField(
        'Error Mappings',
        'errors.mappings',
        _formatJson(errA['mappings']),
        _formatJson(errB['mappings']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Error Classification Mappings',
      icon: Icons.warning_amber_outlined,
      items: items,
    );
  }

  static DomainDiffGroup _diffCapabilities(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final items = <DomainDiffItem>[
      _compareField(
        'Declared Capabilities',
        'capabilities',
        _formatJson(a['capabilities']),
        _formatJson(b['capabilities']),
      ),
    ];

    return DomainDiffGroup(
      domainName: 'Capabilities',
      icon: Icons.verified_user_outlined,
      items: items,
    );
  }

  static DomainDiffItem _compareField(
      String label, String path, String? valA, String? valB) {
    DiffChangeType changeType;
    if (valA == null && valB != null) {
      changeType = DiffChangeType.added;
    } else if (valA != null && valB == null) {
      changeType = DiffChangeType.removed;
    } else if (valA != valB) {
      changeType = DiffChangeType.modified;
    } else {
      changeType = DiffChangeType.unchanged;
    }

    return DomainDiffItem(
      fieldLabel: label,
      fieldPath: path,
      valueA: valA,
      valueB: valB,
      changeType: changeType,
    );
  }

  static String? _formatJson(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }
}
