part of '../spaces_pages.dart';

/// Names a new Thread from complete opening words, with a bounded fallback for
/// a first word longer than the title limit.
String threadNameFromMessage(String text) {
  final words =
      text.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
  var title = '';
  for (final word in words) {
    final next = title.isEmpty ? word : '$title $word';
    if (next.characters.length > 22) {
      return title.isEmpty ? word.characters.take(22).toString() : title;
    }
    title = next;
  }
  return title.isEmpty ? 'New Thread' : title;
}

/// Space landing surface. Threads are created by an explicit name or first send.
class NewThreadPage extends StatefulWidget {
  const NewThreadPage({
    super.key,
    required this.space,
    required this.dataSource,
    required this.createThread,
    required this.onOpenThread,
    required this.discussionCache,
    required this.workHistoryCache,
    required this.threadViewStateStore,
    this.catalogs,
    this.workflowConfigurations,
    this.currentUserId,
    this.currentUserName,
    this.viewerEmail,
  });

  final AxSpace space;
  final AxDataSource dataSource;
  final Future<AxThread> Function(String name) createThread;
  final ValueChanged<AxThread> onOpenThread;
  final AxDiscussionCache discussionCache;
  final AxWorkHistoryCache workHistoryCache;
  final AxThreadViewStateStore threadViewStateStore;
  final AxSessionCatalogs? catalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? currentUserId;
  final String? currentUserName;
  final String? viewerEmail;

  @override
  State<NewThreadPage> createState() => _NewThreadPageState();
}

class _NewThreadPageState extends State<NewThreadPage> {
  final _pageKey = GlobalKey<_ThreadPageState>();
  AxThread? _createdThread;
  final _nameController = TextEditingController();
  bool _busy = false;
  String? _creationError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<T> _whileBusy<T>(Future<T> Function() action) async {
    setState(() {
      _busy = true;
      _creationError = null;
    });
    try {
      return await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createNamedThread() async {
    if (_busy || _nameController.text.trim().isEmpty) return;
    try {
      await _whileBusy(() async {
        final thread = await _ensureThread('');
        await _open(
            thread, '', _pageKey.currentState?._tabController.index ?? 0);
      });
    } catch (error) {
      if (mounted) setState(() => _creationError = error.toString());
    }
  }

  Future<AxThread> _ensureThread(String text) async {
    if (_createdThread != null) return _createdThread!;
    if (!widget.space.effectivePermissions.manageOwnThreads) {
      throw StateError('You cannot create Threads in this Space.');
    }
    final customName = _nameController.text.trim();
    final created = await widget.createThread(
        customName.isEmpty ? threadNameFromMessage(text) : customName);
    if (created.id.isEmpty ||
        created.id.startsWith('local-') ||
        created.spaceId != widget.space.id) {
      throw StateError('Thread creation returned an invalid identity.');
    }
    _createdThread = created;
    return created;
  }

  Future<void> _open(AxThread thread, String submitted, int tab) async {
    if (!mounted) return;
    final page = _pageKey.currentState;
    if (page == null) return;
    final state = page._currentThreadViewState().toJson();
    // Preserve the other composer and any text authored during submission.
    if (tab == 0 && page._discussionController.text == submitted) {
      state.remove('chatDraft');
    }
    if (tab == 1 && page._requestController.text == submitted) {
      state.remove('workDraft');
    }
    state['tabIndex'] = tab;
    final userId = widget.currentUserId;
    if (userId != null && userId.isNotEmpty) {
      try {
        await widget.threadViewStateStore.save(
          userId: userId,
          threadId: thread.id,
          state: AxThreadViewState.fromJson(state),
        );
      } catch (_) {
        // Submission already succeeded. A local view-state failure must not
        // present it as a failed send and invite a duplicate message.
        if (mounted) {
          ScaffoldMessenger.of(context).showNotice(const SnackBar(
              content: Text(
                  'Message sent, but the local draft could not be saved.')));
        }
      }
    }
    if (mounted) widget.onOpenThread(thread);
  }

  Future<void> _sendChat(String text) => _whileBusy(() async {
        final thread = await _ensureThread(text);
        await widget.discussionCache.send(thread.id, text,
            userId: widget.currentUserId, userName: widget.currentUserName);
        await _open(thread, text, 0);
      });

  Future<String> _sendWork(
          String text,
          String workflow,
          List<Map<String, dynamic>> inputs,
          String _,
          Map<String, dynamic> selection) =>
      _whileBusy(() async {
        final reference = _pageKey.currentState?._effectiveWorkflow ?? workflow;
        final version = int.tryParse(reference.split(':v').last) ?? 1;
        final thread = await _ensureThread(text);
        final result = await widget.workHistoryCache.createRequest(
          thread.id,
          prompt: text,
          workflowId: workflow,
          workflowVersion: version,
          attachments: inputs,
          executionSelection: selection,
          requestedByUserId: widget.currentUserId,
          requestedByName: widget.currentUserName,
          execute: (prompt, workflowId, attachments, key) => widget.dataSource
              .createWorkRequest(
                  threadId: thread.id,
                  workflowId: workflowId,
                  prompt: prompt,
                  attachments: attachments,
                  idempotencyKey: key),
          executeWithSelection:
              (prompt, workflowId, attachments, key, options) =>
                  widget.dataSource.createWorkRequestWithSelection(
                      threadId: thread.id,
                      workflowId: workflowId,
                      prompt: prompt,
                      attachments: attachments,
                      idempotencyKey: key,
                      executionSelection: options),
        );
        await _open(thread, text, 1);
        return result;
      });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1681),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.space.description.trim().isNotEmpty) ...[
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: SingleChildScrollView(
                            child: Text(widget.space.description)),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      key: const ValueKey('new-thread-name'),
                      controller: _nameController,
                      enabled: !_busy &&
                          _createdThread == null &&
                          widget.space.effectivePermissions.manageOwnThreads,
                      maxLength: 22,
                      decoration: InputDecoration(
                        labelText: 'Thread name',
                        hintText:
                            'Optional — generated from your first message',
                        counterText: '',
                        suffixIcon: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _nameController,
                          builder: (context, value, _) => TextButton(
                            style: TextButton.styleFrom(
                                foregroundColor:
                                    Theme.of(context).colorScheme.onSurface),
                            onPressed: !_busy &&
                                    value.text.trim().isNotEmpty &&
                                    widget.space.effectivePermissions
                                        .manageOwnThreads
                                ? _createNamedThread
                                : null,
                            child: const Text('Create Thread'),
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _createNamedThread(),
                    ),
                    if (_creationError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_creationError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                  ]),
            ),
          )),
          Expanded(child: _threadPage()),
        ],
      );

  Widget _threadPage() => ThreadPage(
        key: _pageKey,
        isDraft: true,
        draftBusy: _busy,
        space: widget.space,
        thread: AxThread(
          id: 'draft-space-${widget.space.id}',
          spaceId: widget.space.id,
          name: 'New Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: '',
          canExecuteWork: widget.space.effectivePermissions.work &&
              widget.space.effectivePermissions.manageOwnThreads,
        ),
        dataSource: widget.dataSource,
        discussionCache: widget.discussionCache,
        workHistoryCache: widget.workHistoryCache,
        catalogs: widget.catalogs,
        workflowConfigurations: widget.workflowConfigurations,
        currentUserId: widget.currentUserId,
        currentUserName: widget.currentUserName,
        viewerEmail: widget.viewerEmail,
        onBackToSpace: () {},
        onArchive: () {},
        onSendDraftDiscussion: _sendChat,
        onRunWorkWithSelection: _sendWork,
      );
}
