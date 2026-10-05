import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'conclave_markdown_body.dart';

enum MarkdownFormat {
  bold,
  italic,
  heading,
  inlineCode,
  codeBlock,
  quote,
  link,
  bulletList,
  numberedList,
  taskList,
}

/// Edits only Markdown source and keeps the edited content selected.
void formatMarkdown(TextEditingController controller, MarkdownFormat format) {
  final text = controller.text;
  final selection = controller.selection;
  var start = selection.isValid ? selection.start : text.length;
  var end = selection.isValid ? selection.end : text.length;
  final lineOperation = switch (format) {
    MarkdownFormat.heading ||
    MarkdownFormat.quote ||
    MarkdownFormat.bulletList ||
    MarkdownFormat.numberedList ||
    MarkdownFormat.taskList =>
      true,
    _ => false,
  };
  if (lineOperation) {
    start = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    if (end > start && text[end - 1] == '\n') end--;
    final nextNewline = text.indexOf('\n', end);
    end = nextNewline < 0 ? text.length : nextNewline;
    final lines = text.substring(start, end).split('\n');
    final unquote = format == MarkdownFormat.quote &&
        lines.every((line) => line.startsWith('> '));
    final replacement = [
      for (var i = 0; i < lines.length; i++)
        if (unquote)
          lines[i].substring(2)
        else
          '${switch (format) {
            MarkdownFormat.heading => '## ',
            MarkdownFormat.quote => '> ',
            MarkdownFormat.bulletList => '- ',
            MarkdownFormat.numberedList => '${i + 1}. ',
            _ => '- [ ] ',
          }}${lines[i]}',
    ].join('\n');
    controller.value = TextEditingValue(
      text: text.replaceRange(start, end, replacement),
      selection: TextSelection(
          baseOffset: start, extentOffset: start + replacement.length),
    );
    return;
  }
  final selected = text.substring(start, end);
  final (prefix, suffix, placeholder) = switch (format) {
    MarkdownFormat.bold => ('**', '**', 'bold text'),
    MarkdownFormat.italic => ('*', '*', 'italic text'),
    MarkdownFormat.inlineCode => ('`', '`', 'code'),
    MarkdownFormat.codeBlock => ('```\n', '\n```', 'code'),
    MarkdownFormat.link => ('[', '](url)', 'link text'),
    _ => ('', '', ''),
  };
  final content = selected.isEmpty ? placeholder : selected;
  controller.value = TextEditingValue(
    text: text.replaceRange(start, end, '$prefix$content$suffix'),
    selection: format == MarkdownFormat.link
        ? TextSelection(
            baseOffset: start + prefix.length + content.length + 2,
            extentOffset: start + prefix.length + content.length + 5)
        : TextSelection(
            baseOffset: start + prefix.length,
            extentOffset: start + prefix.length + content.length),
  );
}

class MarkdownComposer extends StatefulWidget {
  const MarkdownComposer(
      {super.key,
      required this.controller,
      this.onSend,
      this.onSubmit,
      this.compact = false,
      this.autofocus = false,
      this.enabled = true,
      this.labelText,
      this.hintText = 'Write a message…',
      this.minLines = 2,
      this.maxLines = 8});

  final TextEditingController controller;
  final VoidCallback? onSend;
  final VoidCallback? onSubmit;
  final bool compact;
  final bool autofocus;
  final bool enabled;
  final String? labelText;
  final String hintText;
  final int minLines;
  final int maxLines;

  @override
  State<MarkdownComposer> createState() => _MarkdownComposerState();
}

class _MarkdownComposerState extends State<MarkdownComposer> {
  final _focus = FocusNode();
  bool _preview = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _format(MarkdownFormat format) {
    if (!widget.enabled) return;
    formatMarkdown(widget.controller, format);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        padding: EdgeInsets.all(widget.compact ? 6 : 10),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            TextButton(
                onPressed: () => setState(() => _preview = false),
                child: Text('Write',
                    style: TextStyle(
                        fontWeight: !_preview ? FontWeight.bold : null))),
            TextButton(
                onPressed: () => setState(() => _preview = true),
                child: Text('Preview',
                    style: TextStyle(
                        fontWeight: _preview ? FontWeight.bold : null))),
            const Spacer(),
            Tooltip(
              message: 'Workstream content is GitHub-Flavored Markdown source.',
              child: Text('Markdown',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
            ),
          ]),
          if (!_preview) ...[
            Wrap(children: [
              for (final (format, label, icon) in const [
                (MarkdownFormat.bold, 'Bold', Icons.format_bold),
                (MarkdownFormat.italic, 'Italic', Icons.format_italic),
                (MarkdownFormat.heading, 'Heading', Icons.title),
                (MarkdownFormat.inlineCode, 'Inline code', Icons.code),
                (MarkdownFormat.codeBlock, 'Code block', Icons.data_object),
                (MarkdownFormat.quote, 'Quote', Icons.format_quote),
                (MarkdownFormat.link, 'Link', Icons.link),
                (
                  MarkdownFormat.bulletList,
                  'Bullet list',
                  Icons.format_list_bulleted
                ),
                (
                  MarkdownFormat.numberedList,
                  'Numbered list',
                  Icons.format_list_numbered
                ),
                (MarkdownFormat.taskList, 'Task list', Icons.checklist),
              ])
                IconButton(
                    tooltip: label,
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.enabled ? () => _format(format) : null,
                    icon: Icon(icon)),
            ]),
            CallbackShortcuts(
                bindings: {
                  for (final modifier in [true, false]) ...{
                    SingleActivator(LogicalKeyboardKey.keyB,
                        meta: modifier,
                        control: !modifier): () => _format(MarkdownFormat.bold),
                    SingleActivator(LogicalKeyboardKey.keyI,
                            meta: modifier, control: !modifier):
                        () => _format(MarkdownFormat.italic),
                    SingleActivator(LogicalKeyboardKey.keyE,
                            meta: modifier, control: !modifier):
                        () => _format(MarkdownFormat.inlineCode),
                    if (widget.onSend != null || widget.onSubmit != null)
                      SingleActivator(LogicalKeyboardKey.enter,
                          meta: modifier, control: !modifier): () {
                        if (widget.controller.value.composing.isValid &&
                            !widget.controller.value.composing.isCollapsed) {
                          return;
                        }
                        (widget.onSubmit ?? widget.onSend)!();
                      },
                  },
                },
                child: TextField(
                  controller: widget.controller,
                  enabled: widget.enabled,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: widget.compact ? 1 : widget.minLines,
                  maxLines: widget.maxLines,
                  decoration: InputDecoration(
                      labelText: widget.labelText,
                      hintText: widget.hintText,
                      border: InputBorder.none),
                )),
          ] else
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: value.text.isEmpty
                    ? const Text('Nothing to preview yet.')
                    : ConclaveMarkdownBody(data: value.text),
              ),
            ),
          if (widget.onSend != null || widget.onSubmit != null)
            Row(children: [
              Text(
                '${Theme.of(context).platform == TargetPlatform.macOS || Theme.of(context).platform == TargetPlatform.iOS ? '⌘' : 'Ctrl+'} Enter to ${widget.onSend != null ? 'send' : 'save'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const Spacer(),
              if (widget.onSend != null)
                IconButton(
                  tooltip: 'Send message',
                  onPressed: widget.onSend,
                  icon: const Icon(Icons.send_rounded),
                ),
            ]),
        ]),
      );
}
