import 'dart:async';
import 'quiet_notices.dart';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'syntila_code_block.dart';

/// Accept only absolute web URLs. Uri parsing alone normalizes some malformed
/// input, so reject whitespace, backslashes and invalid escapes first.
Uri? validatedMarkdownLink(String? href) {
  if (href == null ||
      href.isEmpty ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(href) ||
      RegExp(r'^https?://[^/?#]*@', caseSensitive: false).hasMatch(href) ||
      RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(href)) {
    return null;
  }
  try {
    final uri = Uri.parse(href);
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.host.contains('%') ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

Future<bool> _launchMarkdownLink(Uri uri) => launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );

/// AX's authored-content contract: raw GFM source, never converted to HTML.
/// Diagnostics should continue to use plain text widgets.
class SyntilaMarkdownBody extends StatelessWidget {
  const SyntilaMarkdownBody({
    super.key,
    required this.data,
    this.openLink = _launchMarkdownLink,
    this.fitContent = false,
    this.preserveBlankLines = false,
    this.onSelectionChanged,
  });

  final String data;
  final bool fitContent;

  /// Notes opt in to visible blank lines without changing saved Markdown or
  /// whitespace rendering in conversation messages.
  final bool preserveBlankLines;

  /// Reports the plain text selected inside this message boundary.
  ///
  /// The callback is intentionally scoped to this message. It does not expose
  /// Markdown source or selection from neighboring messages or shell UI.
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  /// Receives only validated web URLs; injectable for deterministic testing.
  final Future<bool> Function(Uri uri) openLink;

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = validatedMarkdownLink(href);
    String? failure;
    if (uri == null) {
      failure = 'Only valid HTTP or HTTPS links can be opened.';
    } else {
      try {
        if (!await openLink(uri)) failure = 'Could not open this link.';
      } catch (_) {
        failure = 'Could not open this link.';
      }
    }
    if (failure != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showNotice(
        SnackBar(content: Text(failure)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      key: ValueKey<String>(data),
      data: data,
      fitContent: fitContent,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: [if (preserveBlankLines) const _BlankLinesSyntax()],
      // One selection region joins paragraphs, lists and code blocks.
      selectable: false,
      softLineBreak: true,
      builders: {
        'pre': SyntilaCodeBlockBuilder(),
        if (preserveBlankLines) 'note-blank-lines': _BlankLinesBuilder(),
      },
      syntaxHighlighter: SyntilaSyntaxHighlighter(Theme.of(context)),
      styleSheet: SyntilaMarkdownStyleSheet.fromTheme(Theme.of(context)),
      onTapLink: (_, href, __) => unawaited(_openLink(context, href)),
      imageBuilder: (_, __, alt) => Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.image_outlined,
              size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          Text(alt?.isNotEmpty == true ? alt! : 'Image',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
    // MarkdownBody keeps its own native selection disabled so this single
    // region can join paragraphs, lists, tables and custom code blocks. Keep
    // the region at the message boundary: an ancestor SelectionArea could
    // otherwise make Select All include neighboring messages or shell UI.
    return SelectionArea(
      onSelectionChanged: onSelectionChanged,
      child: _MarkdownSelectionOrder(child: body),
    );
  }
}

/// Let the Markdown parser own code fences, lists and other block structure;
/// only blank lines it would otherwise discard become visual spacers.
class _BlankLinesSyntax extends md.BlockSyntax {
  const _BlankLinesSyntax();

  // Formatting a multiline selection as headings prefixes its empty lines too.
  // Preserve those empty ATX headings just like blank lines, only in Notes.
  @override
  RegExp get pattern => RegExp(r'^(?:[ \t]*| {0,3}#{1,6}(?:[ \t]+#*[ \t]*)?)$');

  @override
  md.Node parse(md.BlockParser parser) {
    var count = 0;
    while (!parser.isDone && pattern.hasMatch(parser.current.content)) {
      count++;
      parser.advance();
    }
    parser.encounteredBlankLine = true;
    return md.Element('note-blank-lines', [])..attributes['count'] = '$count';
  }
}

class _BlankLinesBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final style = SyntilaMarkdownStyleSheet.fromTheme(Theme.of(context)).p;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 14) *
            (style?.height ?? 1.5);
    return SizedBox(
      height: lineHeight * int.parse(element.attributes['count']!),
    );
  }
}

// Horizontal scrollables treat a point to their left as preceding their
// content, even when it is below them. Indented code/tables therefore capture
// drags on later paragraphs. Resolve vertical block order before forwarding
// those out-of-bounds edges; in-block gestures retain native scrolling.
class _MarkdownSelectionOrder extends StatefulWidget {
  const _MarkdownSelectionOrder({required this.child});
  final Widget child;

  @override
  State<_MarkdownSelectionOrder> createState() =>
      _MarkdownSelectionOrderState();
}

class _MarkdownSelectionOrderState extends State<_MarkdownSelectionOrder> {
  final _delegate = _MarkdownSelectionDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectionContainer(
        delegate: _delegate,
        child: widget.child,
      );
}

class _MarkdownSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectionResult dispatchSelectionEventToChild(
      Selectable selectable, SelectionEvent event) {
    if (event is SelectionEdgeUpdateEvent) {
      final bounds = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        Offset.zero & selectable.size,
      );
      final point = event.globalPosition;
      final Offset adjusted;
      if (point.dy > bounds.bottom) {
        adjusted = Offset(bounds.right + 1, point.dy);
      } else if (point.dy < bounds.top) {
        adjusted = Offset(bounds.left - 1, point.dy);
      } else {
        adjusted = point;
      }
      event = event.type == SelectionEventType.startEdgeUpdate
          ? SelectionEdgeUpdateEvent.forStart(
              globalPosition: adjusted, granularity: event.granularity)
          : SelectionEdgeUpdateEvent.forEnd(
              globalPosition: adjusted, granularity: event.granularity);
    }
    return super.dispatchSelectionEventToChild(selectable, event);
  }
}

/// One light/dark theme-derived style sheet for every AX Markdown surface.
abstract final class SyntilaMessageTypography {
  static TextStyle fromTheme(ThemeData theme) => TextStyle(
        fontFamily: SyntilaTypography.fontFamily,
        fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.6,
        color: SyntilaColors.textPrimary(theme.brightness == Brightness.dark),
      );
}

abstract final class SyntilaMarkdownStyleSheet {
  static MarkdownStyleSheet fromTheme(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final body = SyntilaMessageTypography.fromTheme(theme);
    TextStyle heading(double size) => body.copyWith(
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1.3,
        );
    final code = body.copyWith(
      fontFamily: SyntilaTypography.fontFamilyMono,
      fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
      fontSize: (body.fontSize ?? 14) * 0.9,
      backgroundColor: SyntilaColors.codeBackground(isDark),
    );
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      a: TextStyle(
          color: SyntilaColors.primaryForeground(isDark),
          decoration: TextDecoration.underline),
      h1: heading(26),
      h2: heading(22),
      h3: heading(19),
      h4: heading(17),
      h5: heading(15),
      h6: heading(14),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      code: code,
      listBullet: body,
      listIndent: 24,
      blockSpacing: 10,
      checkbox: body.copyWith(color: SyntilaColors.primary),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      // Intrinsic columns let flutter_markdown_plus place wide tables in its
      // horizontal scroll container instead of forcing them into the message
      // width and causing overflow.
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableBorder: TableBorder.all(color: SyntilaColors.border(isDark)),
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      tableHeadCellsDecoration: BoxDecoration(
        color: SyntilaColors.codeBackground(isDark),
      ),
      blockquote: body.copyWith(color: SyntilaColors.textSecondary(isDark)),
      blockquotePadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      blockquoteDecoration: BoxDecoration(
        color: isDark
            ? SyntilaColors.surfaceDark
            : SyntilaColors.surfaceHoverLight,
        border: Border(
            left: BorderSide(color: SyntilaColors.border(isDark), width: 3)),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: SyntilaColors.codeBackground(isDark),
        border: Border.all(color: SyntilaColors.border(isDark)),
        borderRadius: BorderRadius.circular(SyntilaRadius.md),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: SyntilaColors.border(isDark))),
      ),
    );
  }
}
