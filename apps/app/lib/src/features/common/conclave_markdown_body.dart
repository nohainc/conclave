import 'dart:async';

import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'conclave_code_block.dart';

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
class ConclaveMarkdownBody extends StatelessWidget {
  const ConclaveMarkdownBody({
    super.key,
    required this.data,
    this.openLink = _launchMarkdownLink,
    this.fitContent = false,
  });

  final String data;
  final bool fitContent;

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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(failure)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
          child: MarkdownBody(
        data: data,
        fitContent: fitContent,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        // One selection region joins paragraphs, lists and code blocks.
        selectable: false,
        softLineBreak: true,
        builders: {'pre': ConclaveCodeBlockBuilder()},
        syntaxHighlighter: ConclaveSyntaxHighlighter(Theme.of(context)),
        styleSheet: ConclaveMarkdownStyleSheet.fromTheme(Theme.of(context)),
        onTapLink: (_, href, __) => unawaited(_openLink(context, href)),
        imageBuilder: (_, __, alt) => Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.image_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            Text(alt?.isNotEmpty == true ? alt! : 'Image',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ));
}

/// One light/dark theme-derived style sheet for every AX Markdown surface.
abstract final class ConclaveMessageTypography {
  static TextStyle fromTheme(ThemeData theme) => TextStyle(
        fontFamily: ConclaveTypography.fontFamily,
        fontFamilyFallback: ConclaveTypography.fontFamilyFallback,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.6,
        color: ConclaveColors.textPrimary(theme.brightness == Brightness.dark),
      );
}

abstract final class ConclaveMarkdownStyleSheet {
  static MarkdownStyleSheet fromTheme(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final body = ConclaveMessageTypography.fromTheme(theme);
    TextStyle heading(double size) => body.copyWith(
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1.3,
        );
    final code = body.copyWith(
      fontFamily: ConclaveTypography.fontFamilyMono,
      fontFamilyFallback: ConclaveTypography.fontFamilyMonoFallback,
      fontSize: (body.fontSize ?? 14) * 0.9,
      backgroundColor: ConclaveColors.codeBackground(isDark),
    );
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      a: TextStyle(
          color: ConclaveColors.primaryForeground(isDark),
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
      checkbox: body.copyWith(color: ConclaveColors.primary),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      tableBorder: TableBorder.all(color: ConclaveColors.border(isDark)),
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      tableHeadCellsDecoration: BoxDecoration(
        color: ConclaveColors.codeBackground(isDark),
      ),
      blockquote: body.copyWith(color: ConclaveColors.textSecondary(isDark)),
      blockquotePadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      blockquoteDecoration: BoxDecoration(
        color: isDark
            ? ConclaveColors.surfaceDark
            : ConclaveColors.surfaceHoverLight,
        border: Border(
            left: BorderSide(color: ConclaveColors.border(isDark), width: 3)),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: ConclaveColors.codeBackground(isDark),
        border: Border.all(color: ConclaveColors.border(isDark)),
        borderRadius: BorderRadius.circular(ConclaveRadius.md),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: ConclaveColors.border(isDark))),
      ),
    );
  }
}
