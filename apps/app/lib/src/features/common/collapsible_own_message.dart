import 'package:flutter/material.dart';

/// A compact source preview for long own messages, with full Markdown on demand.
class CollapsibleOwnMessage extends StatefulWidget {
  const CollapsibleOwnMessage({
    super.key,
    required this.data,
    required this.child,
    this.enabled = true,
    this.toggleColor,
    this.footerBuilder,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.footerGap = 6,
  });

  final String data;
  final Widget child;
  final bool enabled;

  /// Color of the Show more / Hide more text; defaults to the muted text color.
  final Color? toggleColor;

  /// Lets the caller place the toggle on its own meta line (for example before
  /// the timestamp). It receives null when the message is not collapsible.
  /// Without it, the toggle renders alone under the message.
  final Widget Function(BuildContext context, Widget? toggle)? footerBuilder;

  /// Alignment of the content and footer inside the message column.
  final CrossAxisAlignment crossAxisAlignment;
  final double footerGap;

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
    if (!widget.enabled) return _withFooter(context, widget.child, null);
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
      if (!overflows) return _withFooter(context, widget.child, null);
      final color =
          widget.toggleColor ?? Theme.of(context).colorScheme.onSurfaceVariant;
      // Plain clickable text, not a button: no padding, ink, or min size.
      final toggle = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(_expanded ? 'Hide more' : 'Show more',
              style: TextStyle(fontSize: 12, color: color)),
        ),
      );
      return _withFooter(
        context,
        _expanded
            ? widget.child
            : Text(widget.data, maxLines: 4, overflow: TextOverflow.ellipsis),
        toggle,
      );
    });
  }

  Widget _withFooter(BuildContext context, Widget content, Widget? toggle) {
    final builder = widget.footerBuilder;
    if (builder == null) {
      if (toggle == null) return content;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: widget.crossAxisAlignment,
        children: [content, SizedBox(height: widget.footerGap), toggle],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.crossAxisAlignment,
      children: [
        content,
        SizedBox(height: widget.footerGap),
        builder(context, toggle),
      ],
    );
  }
}
