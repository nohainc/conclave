import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../brand.dart';

/// Styled code snippet widget with language badge and one-click copy button.
class CodeBlockView extends StatefulWidget {
  const CodeBlockView({
    super.key,
    required this.code,
    this.language = 'code',
  });

  final String code;
  final String language;

  @override
  State<CodeBlockView> createState() => _CodeBlockViewState();
}

class _CodeBlockViewState extends State<CodeBlockView> {
  bool _copied = false;

  Future<void> _copyCode() async {
    setState(() => _copied = true);
    await Clipboard.setData(ClipboardData(text: widget.code));
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? ConclaveBrand.darkCodeBackground : ConclaveBrand.lightCodeBackground;
    final borderColor = isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;
    final codeTextColor = isDark ? const Color(0xffe2e8f0) : const Color(0xff1e293b);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: Language label + Copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
              color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.language.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                  ),
                ),
                InkWell(
                  onTap: _copyCode,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 13,
                          color: _copied ? ConclaveBrand.success : (isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? 'Copied' : 'Copy',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: _copied ? ConclaveBrand.success : (isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code content with horizontal scroll
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              widget.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.45,
                color: codeTextColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper widget that parses mixed text with markdown code fences into structured widgets
class MarkdownMessageBody extends StatelessWidget {
  const MarkdownMessageBody({
    super.key,
    required this.text,
    this.textStyle,
  });

  final String text;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final parts = _parseCodeBlocks(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts.map((part) {
        if (part.isCode) {
          return CodeBlockView(code: part.content, language: part.language);
        }
        return SelectableText(
          part.content,
          style: textStyle ?? TextStyle(
            fontSize: 13.5,
            height: 1.45,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        );
      }).toList(),
    );
  }

  List<_ParsedSnippet> _parseCodeBlocks(String raw) {
    final snippets = <_ParsedSnippet>[];
    final lines = raw.split('\n');
    final textBuffer = StringBuffer();
    final codeBuffer = StringBuffer();
    var inCode = false;
    var currentLang = 'code';

    for (final line in lines) {
      if (line.trim().startsWith('```')) {
        if (inCode) {
          snippets.add(_ParsedSnippet(
            content: codeBuffer.toString().trimRight(),
            isCode: true,
            language: currentLang,
          ));
          codeBuffer.clear();
          inCode = false;
        } else {
          if (textBuffer.isNotEmpty) {
            snippets.add(_ParsedSnippet(
              content: textBuffer.toString().trimRight(),
              isCode: false,
            ));
            textBuffer.clear();
          }
          final tag = line.trim().substring(3).trim();
          currentLang = tag.isNotEmpty ? tag : 'code';
          inCode = true;
        }
      } else {
        if (inCode) {
          codeBuffer.writeln(line);
        } else {
          textBuffer.writeln(line);
        }
      }
    }

    if (inCode && codeBuffer.isNotEmpty) {
      snippets.add(_ParsedSnippet(
        content: codeBuffer.toString().trimRight(),
        isCode: true,
        language: currentLang,
      ));
    } else if (textBuffer.isNotEmpty) {
      snippets.add(_ParsedSnippet(
        content: textBuffer.toString().trimRight(),
        isCode: false,
      ));
    }

    return snippets.isEmpty ? [_ParsedSnippet(content: raw, isCode: false)] : snippets;
  }
}

class _ParsedSnippet {
  const _ParsedSnippet({
    required this.content,
    required this.isCode,
    this.language = 'code',
  });

  final String content;
  final bool isCode;
  final String language;
}
