import 'dart:async';
import 'quiet_notices.dart';

import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
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
    final body = _buildGpt(context);
    // Keep the region at the message boundary: an ancestor SelectionArea could
    // otherwise make Select All include neighboring messages or shell UI.
    return SelectionArea(
      onSelectionChanged: onSelectionChanged,
      child: _MarkdownSelectionOrder(child: body),
    );
  }

  /// Conversation messages: gpt_markdown sized to content, one per message so
  /// the thread's list virtualizes messages while each body caches segments.
  Widget _buildGpt(BuildContext context) {
    final theme = Theme.of(context);
    final data =
        preserveBlankLines ? visibleBlankLinesMarkdown(this.data) : this.data;
    // gpt_markdown's image hook receives only the URL; recover the alt text.
    final imageAlts = {
      for (final m
          in RegExp(r'!\[([^\]]*)\]\(\s*<?([^)\s>]*)').allMatches(data))
        m.group(2)!: m.group(1)!,
    };
    final body = GptMarkdown(
      data,
      key: ValueKey<String>(data),
      style: SyntilaMessageTypography.fromTheme(theme),
      styleSheet: SyntilaGptMarkdownStyleSheet.fromTheme(theme),
      // Authored content is Markdown only; raw HTML stays literal text.
      html: false,
      isStreaming: false,
      onLinkTap: (url, _) => unawaited(_openLink(context, url)),
      // Fence bodies keep their trailing newline so copy matches the source.
      codeBuilder: (_, language, code, __) => SyntilaCodeBlock(
          code: code.endsWith('\n') ? code : '$code\n', language: language),
      // Read-only task markers; Material checkboxes need a Material ancestor.
      checkboxBuilder: (_, checked, content, __) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8, top: 2),
            child: Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: SyntilaColors.primary,
              semanticLabel: checked ? 'Checked' : 'Unchecked',
            ),
          ),
          Flexible(child: content),
        ],
      ),
      // Remote images are never fetched from message content.
      imageBuilder: (context, url, __, ___) => Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.image_outlined,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          Text(imageAlts[url]?.isNotEmpty == true ? imageAlts[url]! : 'Image',
              style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    if (fitContent) return body;
    return SizedBox(width: double.infinity, child: body);
  }
}

/// Notes show extra blank lines as space, which Markdown would collapse.
/// Each blank line beyond the paragraph break becomes a zero-width-space
/// paragraph for display only (Dart's trim keeps U+200B, unlike U+00A0); the saved note is unchanged. Empty ATX
/// headings (left by heading-formatting a multiline selection) count as blank
/// lines. Fenced code keeps its whitespace untouched.
String visibleBlankLinesMarkdown(String source) {
  final lines = source.split('\n');
  if (source.endsWith('\n')) lines.removeLast();
  final blank = RegExp(r'^(?:[ \t]*| {0,3}#{1,6}(?:[ \t]+#*[ \t]*)?)$');
  final fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
  final out = <String>[];
  String? openFence;
  var run = 0;
  var seenContent = false;
  void flush({required bool atEnd}) {
    if (run == 0) return;
    // Between blocks the first blank line is the normal paragraph break.
    final extra = seenContent && !atEnd ? run - 1 : run;
    out.add('');
    for (var i = 0; i < extra; i++) {
      out
        ..add('\u200B')
        ..add('');
    }
    run = 0;
  }

  for (final line in lines) {
    final marker = fence.firstMatch(line)?.group(1);
    if (openFence != null) {
      out.add(line);
      if (marker != null &&
          marker[0] == openFence[0] &&
          marker.length >= openFence.length) {
        openFence = null;
      }
      continue;
    }
    if (blank.hasMatch(line)) {
      run++;
      continue;
    }
    flush(atEnd: false);
    seenContent = true;
    if (marker != null) openFence = marker;
    out.add(line);
  }
  flush(atEnd: true);
  return out.join('\n');
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
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
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
      h1: heading(22),
      h2: heading(19),
      h3: heading(17),
      h4: heading(15),
      h5: heading(14),
      h6: heading(13),
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

/// gpt_markdown counterpart of [SyntilaMarkdownStyleSheet] for messages.
abstract final class SyntilaGptMarkdownStyleSheet {
  static GptMarkdownStyleSheet fromTheme(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final body = SyntilaMessageTypography.fromTheme(theme);
    return GptMarkdownStyleSheet(
      heading: HeadingStyle(
        textStyle: TextStyle(
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: body.color,
        ),
      ),
      link: LinkStyle(
        color: SyntilaColors.primaryForeground(isDark),
        hoverColor: SyntilaColors.primaryForeground(isDark),
        decoration: TextDecoration.underline,
      ),
      inlineCode: InlineCodeStyle(
        fontFamily: SyntilaTypography.fontFamilyMono,
        fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
        fontSizeFactor: 0.9,
        color: body.color,
        backgroundColor: SyntilaColors.codeBackground(isDark),
        borderColor: SyntilaColors.border(isDark),
      ),
      list:
          ListStyle(bulletColor: body.color, markerTextStyle: body, indent: 24),
      table: TableStyle(
        borderColor: SyntilaColors.border(isDark),
        cellPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        headerBackground: SyntilaColors.codeBackground(isDark),
        headerTextStyle: body.copyWith(fontWeight: FontWeight.w600),
      ),
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barColor: SyntilaColors.border(isDark),
        backgroundColor: isDark
            ? SyntilaColors.surfaceDark
            : SyntilaColors.surfaceHoverLight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: body.copyWith(color: SyntilaColors.textSecondary(isDark)),
      ),
      hr: HrStyle(color: SyntilaColors.border(isDark), thickness: 1),
    );
  }
}
