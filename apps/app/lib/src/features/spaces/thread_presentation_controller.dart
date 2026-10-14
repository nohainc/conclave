import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ax/ax_models.dart';
import '../../ax/ax_work_activity.dart';
import '../../ax/ax_work_models.dart';
import '../../ax/sync/ax_discussion_cache.dart';
import '../../ax/sync/ax_work_history.dart';

/// Immutable Chat projection used by the Thread presentation layer.
class ThreadChatPresentationSnapshot {
  const ThreadChatPresentationSnapshot({
    required this.generation,
    required this.messages,
    required this.hasData,
    required this.isFetching,
    required this.loadingOlder,
    required this.olderCursor,
    required this.error,
  });

  final int generation;
  final List<AxDiscussionMessage> messages;
  final bool hasData;
  final bool isFetching;
  final bool loadingOlder;
  final String? olderCursor;
  final Object? error;

  @override
  bool operator ==(Object other) =>
      other is ThreadChatPresentationSnapshot &&
      generation == other.generation &&
      listEquals(messages, other.messages) &&
      hasData == other.hasData &&
      isFetching == other.isFetching &&
      loadingOlder == other.loadingOlder &&
      olderCursor == other.olderCursor &&
      error?.toString() == other.error?.toString();

  @override
  int get hashCode => Object.hash(
        generation,
        Object.hashAll(messages),
        hasData,
        isFetching,
        loadingOlder,
        olderCursor,
        error?.toString(),
      );
}

/// Immutable Work projection used by the Thread presentation layer.
class ThreadWorkPresentationSnapshot {
  const ThreadWorkPresentationSnapshot({
    required this.generation,
    required this.requests,
    required this.hasData,
    required this.isFetching,
    required this.loadingOlder,
    required this.olderCursor,
    required this.error,
    required this.submitting,
    required this.localProgress,
    this.revision = 0,
  });

  final int generation;
  final List<AxWorkRequest> requests;
  final bool hasData;
  final bool isFetching;
  final bool loadingOlder;
  final AxWorkRequestCursor? olderCursor;
  final Object? error;
  final bool submitting;
  final Map<String, String> localProgress;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is ThreadWorkPresentationSnapshot &&
      generation == other.generation &&
      listEquals(requests, other.requests) &&
      hasData == other.hasData &&
      isFetching == other.isFetching &&
      loadingOlder == other.loadingOlder &&
      olderCursor == other.olderCursor &&
      error?.toString() == other.error?.toString() &&
      submitting == other.submitting &&
      mapEquals(localProgress, other.localProgress) &&
      revision == other.revision;

  @override
  int get hashCode => Object.hash(
        generation,
        Object.hashAll(requests),
        hasData,
        isFetching,
        loadingOlder,
        olderCursor,
        error?.toString(),
        submitting,
        Object.hashAll(localProgress.entries
            .map((entry) => Object.hash(entry.key, entry.value))),
        revision,
      );
}

class ThreadPaginationPresentationSnapshot {
  const ThreadPaginationPresentationSnapshot({
    required this.chatHasOlder,
    required this.chatLoadingOlder,
    required this.workHasOlder,
    required this.workLoadingOlder,
  });

  final bool chatHasOlder;
  final bool chatLoadingOlder;
  final bool workHasOlder;
  final bool workLoadingOlder;

  @override
  bool operator ==(Object other) =>
      other is ThreadPaginationPresentationSnapshot &&
      chatHasOlder == other.chatHasOlder &&
      chatLoadingOlder == other.chatLoadingOlder &&
      workHasOlder == other.workHasOlder &&
      workLoadingOlder == other.workLoadingOlder;

  @override
  int get hashCode => Object.hash(
        chatHasOlder,
        chatLoadingOlder,
        workHasOlder,
        workLoadingOlder,
      );
}

class ThreadExecutionPresentationSnapshot {
  const ThreadExecutionPresentationSnapshot({
    required this.generation,
    required this.statusByRequest,
  });

  final int generation;
  final Map<String, String> statusByRequest;

  Set<String> get terminalRequestIds => statusByRequest.entries
      .where((entry) => const {
            'completed',
            'failed',
            'cancelled',
            'timed_out',
            'lost'
          }.contains(entry.value))
      .map((entry) => entry.key)
      .toSet();
}

class ThreadComposerPresentationSnapshot {
  const ThreadComposerPresentationSnapshot(this.revision);

  final int revision;
}

enum _ThreadPresentationSlice { chat, work, pagination, composer }

/// Presentation-only coordinator over the existing Thread caches.
///
/// It owns no server data and does not replace `AxDiscussionCache`,
/// `AxWorkHistoryCache`, or `AxWorkActivityStore`. It only snapshots their
/// current projections and schedules independent UI slices.
class ThreadPresentationController {
  ThreadPresentationController({
    required AxWorkActivityStore activityStore,
    VoidCallback? onWorkChanged,
  })  : _activityStore = activityStore,
        _onWorkChanged = onWorkChanged;

  final AxWorkActivityStore _activityStore;
  final VoidCallback? _onWorkChanged;
  final chat = ValueNotifier<ThreadChatPresentationSnapshot?>(null);
  final work = ValueNotifier<ThreadWorkPresentationSnapshot?>(null);
  final pagination = ValueNotifier<ThreadPaginationPresentationSnapshot?>(null);
  final execution = ValueNotifier<ThreadExecutionPresentationSnapshot?>(null);
  final composer = ValueNotifier(const ThreadComposerPresentationSnapshot(0));

  AxDiscussionCache? _discussionCache;
  AxWorkHistoryCache? _workHistoryCache;
  String? _threadId;
  void Function()? _cancelDiscussion;
  void Function()? _cancelWork;
  Timer? _scheduled;
  final _pending = <_ThreadPresentationSlice>{};
  int _generation = 0;
  int _composerRevision = 0;
  int _workRevision = 0;
  bool _disposed = false;

  int get generation => _generation;

  /// Returns the existing per-assignment selector without copying activity
  /// into a second presentation cache. Work cards can subscribe independently.
  Listenable activityListenableForRequest(AxWorkRequest request) =>
      _activityStore.listenableForRequest(request);

  List<AxWorkActivity> activitiesForRequest(AxWorkRequest request) =>
      _activityStore.forRequest(request);

  void attach({
    required String threadId,
    required AxDiscussionCache discussionCache,
    required AxWorkHistoryCache workHistoryCache,
  }) {
    if (_disposed) return;
    _cancelDiscussion?.call();
    _cancelWork?.call();
    _scheduled?.cancel();
    _scheduled = null;
    _pending.clear();
    _generation++;
    _workRevision = 0;
    final generation = _generation;
    _threadId = threadId;
    _discussionCache = discussionCache;
    _workHistoryCache = workHistoryCache;
    _cancelDiscussion = discussionCache.watch(threadId, (_) {
      if (generation != _generation || _disposed) return;
      // Chat mutations include optimistic sends/edits and authoritative read
      // failures. Publish the isolated Chat slice promptly; Work cosmetic
      // bursts remain frame-batched below.
      _publishChat(generation);
      _schedule(_ThreadPresentationSlice.pagination, generation);
    });
    _cancelWork = workHistoryCache.watch(threadId, () {
      if (generation != _generation || _disposed) return;
      _onWorkChanged?.call();
      final next = _workSnapshot(generation);
      final terminalChanged = !setEquals(
        _terminalIds(execution.value?.statusByRequest),
        _terminalIds(_statusByRequest(next.requests)),
      );
      final submittingChanged = next.submitting != work.value?.submitting;
      final hasLocalRequest = next.requests.any((request) =>
          request.id.startsWith('local-') || request.id.startsWith('temp-'));
      final hadLocalRequest = work.value?.requests.any((request) =>
              request.id.startsWith('local-') ||
              request.id.startsWith('temp-')) ??
          false;
      final localRequestChanged = hasLocalRequest != hadLocalRequest;
      final localProgressChanged =
          !mapEquals(next.localProgress, work.value?.localProgress);
      if (terminalChanged ||
          submittingChanged ||
          localRequestChanged ||
          localProgressChanged) {
        _publishWork(generation, next: next);
        if (terminalChanged) _publishExecution(generation, next.requests);
        if (submittingChanged || localRequestChanged) {
          _composerRevision++;
          composer.value =
              ThreadComposerPresentationSnapshot(_composerRevision);
        }
      } else {
        _schedule(_ThreadPresentationSlice.work, generation);
      }
      _schedule(_ThreadPresentationSlice.pagination, generation);
    });
    _publishChat(generation);
    _publishWork(generation);
    _publishPagination(generation);
    _publishExecution(generation, work.value?.requests ?? const []);
    unawaited(discussionCache
        .synchronize(threadId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  void markComposerChanged() {
    if (_disposed) return;
    _composerRevision++;
    _schedule(_ThreadPresentationSlice.composer, _generation);
  }

  void markWorkChanged() {
    if (_disposed) return;
    _workRevision++;
    _schedule(_ThreadPresentationSlice.work, _generation);
    _schedule(_ThreadPresentationSlice.pagination, _generation);
  }

  void publishLifecycleNow() {
    if (_disposed || _threadId == null) return;
    final requests = _workSnapshot(_generation).requests;
    _publishExecution(_generation, requests);
  }

  void _schedule(_ThreadPresentationSlice slice, int generation) {
    if (_disposed || generation != _generation) return;
    _pending.add(slice);
    if (_scheduled != null) return;
    // Timer.run moves cache bursts out of the current build/notification stack
    // without requesting a frame for a disposed browser view.
    _scheduled = Timer(Duration.zero, () {
      _scheduled = null;
      if (_disposed || generation != _generation) return;
      final pending = Set.of(_pending);
      _pending.clear();
      for (final pendingSlice in pending) {
        switch (pendingSlice) {
          case _ThreadPresentationSlice.chat:
            _publishChat(generation);
          case _ThreadPresentationSlice.work:
            _publishWork(generation);
          case _ThreadPresentationSlice.pagination:
            _publishPagination(generation);
          case _ThreadPresentationSlice.composer:
            composer.value = ThreadComposerPresentationSnapshot(
              _composerRevision,
            );
        }
      }
    });
  }

  ThreadChatPresentationSnapshot _chatSnapshot(int generation) {
    final state = _discussionCache!.peek(_threadId!);
    return ThreadChatPresentationSnapshot(
      generation: generation,
      messages: List.unmodifiable(state.messages),
      hasData: state.hasData,
      isFetching: state.isFetching,
      loadingOlder: state.loadingOlder,
      olderCursor: state.olderCursor,
      error: state.error,
    );
  }

  ThreadWorkPresentationSnapshot _workSnapshot(int generation) {
    final cache = _workHistoryCache!;
    final state = cache.peek(_threadId!);
    return ThreadWorkPresentationSnapshot(
      generation: generation,
      requests: List.unmodifiable(state.requests),
      hasData: state.initialLoaded,
      isFetching: cache.loading(_threadId!),
      loadingOlder: cache.loadingOlder(_threadId!),
      olderCursor: state.olderCursor,
      error: cache.error(_threadId!),
      submitting: cache.submitting(_threadId!),
      localProgress: cache.localProgress(_threadId!),
      revision: _workRevision,
    );
  }

  void _publishChat(int generation) {
    final next = _chatSnapshot(generation);
    if (chat.value != next) chat.value = next;
  }

  void _publishWork(
    int generation, {
    ThreadWorkPresentationSnapshot? next,
  }) {
    final snapshot = next ?? _workSnapshot(generation);
    if (work.value != snapshot) work.value = snapshot;
  }

  void _publishPagination(int generation) {
    final next = ThreadPaginationPresentationSnapshot(
      chatHasOlder: chat.value?.olderCursor != null,
      chatLoadingOlder: chat.value?.loadingOlder ?? false,
      workHasOlder: work.value?.olderCursor != null,
      workLoadingOlder: work.value?.loadingOlder ?? false,
    );
    if (pagination.value != next) pagination.value = next;
  }

  void _publishExecution(int generation, List<AxWorkRequest> requests) {
    final next = ThreadExecutionPresentationSnapshot(
      generation: generation,
      statusByRequest: Map.unmodifiable(_statusByRequest(requests)),
    );
    final current = execution.value;
    if (current == null ||
        !mapEquals(current.statusByRequest, next.statusByRequest) ||
        current.generation != next.generation) {
      execution.value = next;
    }
  }

  Map<String, String> _statusByRequest(List<AxWorkRequest> requests) => {
        for (final request in requests) request.id: request.status,
      };

  Set<String> _terminalIds(Map<String, String>? statuses) => statuses == null
      ? const {}
      : statuses.entries
          .where((entry) => const {
                'completed',
                'failed',
                'cancelled',
                'timed_out',
                'lost',
              }.contains(entry.value))
          .map((entry) => entry.key)
          .toSet();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelDiscussion?.call();
    _cancelWork?.call();
    _scheduled?.cancel();
    chat.dispose();
    work.dispose();
    pagination.dispose();
    execution.dispose();
    composer.dispose();
  }
}
