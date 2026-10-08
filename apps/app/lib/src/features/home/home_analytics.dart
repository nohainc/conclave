import 'package:flutter/foundation.dart';

enum AxHomeAnalyticsAction {
  continueThread('home.continue_thread'),
  acceptInvitation('home.accept_invitation'),
  declineInvitation('home.decline_invitation'),
  resolveAttention('home.resolve_attention'),
  openWhatsNew('home.open_whats_new'),
  openAiUpdate('home.open_ai_update'),
  createSpace('home.create_space'),
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
/// - Home → Continue Thread
/// - Home → Accept invitation
/// - Home → Resolve attention
/// - Home → Open What's New
/// - Home → Open AI Update
/// - Home → Create Space
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

  static void trackContinueThread(
      {required String spaceId,
      required String threadId,
      String? spaceName,
      String? threadTitle}) {
    record(AxHomeAnalyticsEvent(
        action: AxHomeAnalyticsAction.continueThread,
        properties: {
          'spaceId': spaceId,
          'threadId': threadId,
          if (spaceName != null) 'spaceName': spaceName,
          if (threadTitle != null) 'threadTitle': threadTitle,
        }));
  }

  static void trackCreateSpace({required String source}) {
    record(AxHomeAnalyticsEvent(
        action: AxHomeAnalyticsAction.createSpace,
        properties: {'source': source}));
  }

  static void trackAcceptInvitation({
    required String invitationId,
    String? spaceId,
    String? role,
  }) {
    final effectiveSpaceId = spaceId ?? '';
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.acceptInvitation,
      properties: {
        'invitationId': invitationId,
        'spaceId': effectiveSpaceId,
        if (role != null) 'role': role,
      },
    ));
  }

  static void trackDeclineInvitation({
    required String invitationId,
    String? spaceId,
  }) {
    final effectiveSpaceId = spaceId ?? '';
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.declineInvitation,
      properties: {
        'invitationId': invitationId,
        'spaceId': effectiveSpaceId,
      },
    ));
  }

  static void trackResolveAttention({
    required String itemId,
    required String type,
    required String actionLabel,
    String? spaceId,
    String? threadId,
  }) {
    final effectiveSpaceId = spaceId;
    final effectiveThreadId = threadId;
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.resolveAttention,
      properties: {
        'itemId': itemId,
        'type': type,
        'actionLabel': actionLabel,
        if (effectiveSpaceId != null) 'spaceId': effectiveSpaceId,
        if (effectiveThreadId != null) 'threadId': effectiveThreadId,
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

  static void trackOpenRunningRun({
    required String runId,
    String? spaceId,
  }) {
    final effectiveSpaceId = spaceId ?? '';
    record(AxHomeAnalyticsEvent(
      action: AxHomeAnalyticsAction.openRunningRun,
      properties: {
        'runId': runId,
        'spaceId': effectiveSpaceId,
      },
    ));
  }
}
