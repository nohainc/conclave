import 'dart:async';
import 'package:flutter/widgets.dart';
import 'ax_sync_engine.dart';

/// Rebuilds only the resource consumer; cached data renders on the first frame.
class AxQueryBuilder<T> extends StatefulWidget {
  const AxQueryBuilder(
      {super.key,
      required this.engine,
      required this.query,
      required this.builder,
      this.ensure = true});
  final bool ensure;
  final AxSyncEngine engine;
  final AxQuery<T> query;
  final Widget Function(BuildContext, AxQueryState<T>) builder;
  @override
  State<AxQueryBuilder<T>> createState() => _AxQueryBuilderState<T>();
}

class _AxQueryBuilderState<T> extends State<AxQueryBuilder<T>> {
  late AxQueryState<T> state;
  void Function()? cancel;
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    state = widget.engine.peek(widget.query);
    cancel = widget.engine.watch(widget.query, (value) {
      if (mounted) setState(() => state = value);
    }, fireImmediately: false);
    // Attach query state/error handling locally, never to the complete shell.
    if (widget.ensure) {
      unawaited(widget.engine
          .ensure(widget.query)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
  }

  @override
  void didUpdateWidget(covariant AxQueryBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine ||
        oldWidget.query.key != widget.query.key ||
        oldWidget.ensure != widget.ensure) {
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
  Widget build(BuildContext context) => widget.builder(context, state);
}
