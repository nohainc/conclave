import 'package:flutter/foundation.dart';

enum AxHomeAnalyticsAction {
  continueWorkstream('home.continue_workstream'),
  acceptInvitation('home.accept_invitation'),
  declineInvitation('home.decline_invitation'),
  resolveAttention('home.resolve_attention'),
  openWhatsNew('home.open_whats_new'),
  openAiUpdate('home.open_ai_update'),
  createProject('home.create_project'),
  openRunningRun('home.open_running_run');

  const AxHomeAnalyticsAction(this.name);
  final String name;
}

class AxHomeAnalyticsEvent {
  AxHomeAnalyticsEvent({
    required this.action,
    this.properties = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  final AxHomeAnalyticsAction action;
  final Map<String, dynamic> properties;
  final DateTime timestamp;

  String get eventName => action.name;

  Map<String, dynamic> toJson() => {
        'event': eventName,
        'properties': properties,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  @override
  String toString() => 'AxHomeAnalyticsEvent($eventName, $properties)';
}

typedef AxHomeAnalyticsSink = void Function(AxHomeAnalyticsEvent event);

/// Lightweight, product-discovery telemetry service for Conclave AX Home.
///
/// Strictly measures discovery and navigation velocity ("Does Home help people get somewhere useful faster?"):
/// - Home → Continue Workstream
/// - Home → Accept invitation
/// - Home → Resolve attention
/// - Home → Open What's New
/// - Home → Open AI Update
/// - Home → Create Project
///
/// Deliberately avoids vanity telemetry such as isolated "Home viewed" counters.
class AxHomeAnalytics {
  AxHomeAnalytics._();

  static AxHomeAnalyticsSink? _sink;
  static final List<AxHomeAnalyticsEvent> _buffer = [];

  /// Sets or clears the active analytics sink.
  static void setSink(AxHomeAnalyticsSink? sink) {
    _sink = sink;
  }

  /// Returns an unmodifiable list of in-memory events.
  static List<AxHomeAnalyticsEvent> get recordedEvents =>
      List.unmodifiable(_buffer);

  /// Clears in-memory buffer (useful between tests).
  static void reset() {
    _buffer.clear();
  }

  /// Records an analytics event safely.
  static void record(AxHomeAnalyticsEvent event) {
    _buffer.add(event);
    try {
      _sink?.call(event);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('AxHomeAnalytics error: $e');
      }
    }
  }

  static void trackContinueWorkstream({
    required String projectId,
    required String workstreamId,
    String? projectName,
    String? workstreamTitle,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.continueWorkstream,
      properties: {
        'projectId': projectId,
        'workstreamId': workstreamId,
        if (projectName != null) 'projectName': projectName,
        if (workstreamTitle != null) 'workstreamTitle': workstreamTitle,
      },
    ));
  }

  static void trackAcceptInvitation({
    required String invitationId,
    required String projectId,
    String? role,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.acceptInvitation,
      properties: {
        'invitationId': invitationId,
        'projectId': projectId,
        if (role != null) 'role': role,
      },
    ));
  }

  static void trackDeclineInvitation({
    required String invitationId,
    required String projectId,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.declineInvitation,
      properties: {
        'invitationId': invitationId,
        'projectId': projectId,
      },
    ));
  }

  static void trackResolveAttention({
    required String itemId,
    required String type,
    required String actionLabel,
    String? projectId,
    String? workstreamId,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.resolveAttention,
      properties: {
        'itemId': itemId,
        'type': type,
        'actionLabel': actionLabel,
        if (projectId != null) 'projectId': projectId,
        if (workstreamId != null) 'workstreamId': workstreamId,
      },
    ));
  }

  static void trackOpenWhatsNew({
    String? updateId,
    int? unreadCount,
    String? source,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.openWhatsNew,
      properties: {
        if (updateId != null) 'updateId': updateId,
        if (unreadCount != null) 'unreadCount': unreadCount,
        if (source != null) 'source': source,
      },
    ));
  }

  static void trackOpenAiUpdate({
    required String updateId,
    required String workerProfileId,
    String? provider,
    String? type,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.openAiUpdate,
      properties: {
        'updateId': updateId,
        'workerProfileId': workerProfileId,
        if (provider != null) 'provider': provider,
        if (type != null) 'type': type,
      },
    ));
  }

  static void trackCreateProject({
    required String source,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.createProject,
      properties: {
        'source': source,
      },
    ));
  }

  static void trackOpenRunningRun({
    required String runId,
    required String projectId,
  }) {
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.openRunningRun,
      properties: {
        'runId': runId,
        'projectId': projectId,
      },
    ));
  }
}
