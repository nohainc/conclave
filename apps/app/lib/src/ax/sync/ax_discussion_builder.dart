import 'dart:async';
import 'package:flutter/widgets.dart';
import 'ax_discussion_cache.dart';

class AxDiscussionBuilder extends StatefulWidget {
  const AxDiscussionBuilder(
      {super.key,
      required this.cache,
      required this.workstreamId,
      required this.builder});
  final AxDiscussionCache cache;
  final String workstreamId;
  final Widget Function(BuildContext, AxDiscussionState) builder;
  @override
  State<AxDiscussionBuilder> createState() => _AxDiscussionBuilderState();
}

class _AxDiscussionBuilderState extends State<AxDiscussionBuilder> {
  void Function()? cancel;
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    cancel = widget.cache.watch(widget.workstreamId, (_) {
      if (mounted) setState(() {});
    });
    unawaited(widget.cache
        .synchronize(widget.workstreamId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  @override
  void didUpdateWidget(covariant AxDiscussionBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cache != widget.cache ||
        oldWidget.workstreamId != widget.workstreamId) {
      cancel?.call();
      _subscribe();
    }
  }

  @override
  void dispose() {
    cancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.cache.peek(widget.workstreamId));
}
