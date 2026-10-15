import 'package:flutter/material.dart';

/// A compact source preview for long own messages, with full Markdown on demand.
class CollapsibleOwnMessage extends StatefulWidget {
  const CollapsibleOwnMessage({
    super.key,
    required this.data,
    required this.child,
    this.enabled = true,
  });

  final String data;
  final Widget child;
  final bool enabled;

  @override
  State<CollapsibleOwnMessage> createState() => _CollapsibleOwnMessageState();
}

class _CollapsibleOwnMessageState extends State<CollapsibleOwnMessage> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant CollapsibleOwnMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return LayoutBuilder(builder: (context, constraints) {
      final style = DefaultTextStyle.of(context).style;
      final painter = TextPainter(
        text: TextSpan(text: widget.data, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 4,
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      if (!overflows) return widget.child;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_expanded)
            widget.child
          else
            Text(widget.data, maxLines: 4, overflow: TextOverflow.ellipsis),
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? 'Hide more' : 'Show more'),
          ),
        ],
      );
    });
  }
}
