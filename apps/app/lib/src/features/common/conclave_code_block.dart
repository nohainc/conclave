import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight_core.dart' as hl;
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/css.dart';
import 'package:markdown/markdown.dart' as md;

/// The renderer hook lacks a language argument. The block builder supplies
/// fence metadata to this same SyntaxHighlighter implementation per block.
class ConclaveSyntaxHighlighter extends SyntaxHighlighter {
  ConclaveSyntaxHighlighter(this.theme, {this.language = ''});
  final ThemeData theme;
  final String language;
  static final _engine = hl.Highlight()
    ..registerLanguage('dart', dart)
    ..registerLanguage('typescript', typescript)
    ..registerLanguage('javascript', javascript)
    ..registerLanguage('json', json)
    ..registerLanguage('yaml', yaml)
    ..registerLanguage('sql', sql)
    ..registerLanguage('bash', bash)
    ..registerLanguage('python', python)
    ..registerLanguage('xml', xml)
    ..registerLanguage('css', css);

  @override
  TextSpan format(String source) {
    final canonical = switch (language.toLowerCase()) {
      'ts' || 'tsx' => 'typescript',
      'js' || 'jsx' => 'javascript',
      'yml' => 'yaml',
      'sh' || 'shell' => 'bash',
      'py' => 'python',
      'html' => 'xml',
      _ => language.toLowerCase(),
    };
    const supported = {
      'dart',
      'typescript',
      'javascript',
      'json',
      'yaml',
      'sql',
      'bash',
      'python',
      'xml',
      'css'
    };
    final base = TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        height: 1.45,
        color: theme.colorScheme.onSurface);
    if (!supported.contains(canonical) || source.length > 50000) {
      return TextSpan(text: source, style: base);
    }
    final dark = theme.brightness == Brightness.dark;
    Color? tokenColor(String? name) => switch (name) {
          'keyword' ||
          'selector-tag' ||
          'tag' =>
            dark ? const Color(0xffc4b5fd) : const Color(0xff6d28d9),
          'string' ||
          'attr' ||
          'attribute' =>
            dark ? const Color(0xff86efac) : const Color(0xff166534),
          'number' ||
          'literal' =>
            dark ? const Color(0xfffdba74) : const Color(0xff9a3412),
          'comment' => theme.colorScheme.onSurfaceVariant,
          'title' ||
          'built_in' =>
            dark ? const Color(0xff93c5fd) : const Color(0xff1d4ed8),
          _ => null,
        };
    TextSpan span(hl.Node node) => TextSpan(
        text: node.value,
        style: TextStyle(color: tokenColor(node.className)),
        children: node.children?.map(span).toList());
    try {
      return TextSpan(
          style: base,
          children: _engine
              .parse(source, language: canonical)
              .nodes
              ?.map(span)
              .toList());
    } catch (_) {
      return TextSpan(text: source, style: base);
    }
  }
}

class ConclaveCodeBlock extends StatelessWidget {
  const ConclaveCodeBlock({super.key, required this.code, this.language = ''});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              Text(language.isEmpty ? 'Code' : language,
                  style: theme.textTheme.labelSmall),
              const Spacer(),
              IconButton(
                  tooltip: 'Copy code',
                  iconSize: 16,
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(content: Text('Code copied')));
                    }
                  }),
            ])),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(
                ConclaveSyntaxHighlighter(theme, language: language)
                    .format(code))),
      ]),
    );
  }
}

class ConclaveCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final codeElement = element.children
        ?.whereType<md.Element>()
        .where((child) => child.tag == 'code')
        .firstOrNull;
    final tag = codeElement?.attributes['class'] ?? '';
    final language = tag.startsWith('language-') ? tag.substring(9) : '';
    return ConclaveCodeBlock(
        code: codeElement?.textContent ?? element.textContent,
        language: language);
  }
}
