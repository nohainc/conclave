import 'package:flutter/widgets.dart';

import 'html_markdown_view_stub.dart'
    if (dart.library.js_interop) 'html_markdown_view_web.dart' as platform;

/// Prototype opt-in: `--dart-define=SYNTILA_HTML_MARKDOWN=true` renders
/// conversation Markdown in the browser DOM instead of Flutter widgets.
const bool htmlMarkdownEnabled = bool.fromEnvironment('SYNTILA_HTML_MARKDOWN');

/// Whether this platform can host [HtmlMarkdownView].
bool get htmlMarkdownSupported => platform.htmlMarkdownSupported;

/// Browser-rendered Markdown sized to its content height.
///
/// Links are intercepted and handed to [onOpenLink]; the DOM never navigates
/// on its own. Code-block copy buttons use the browser clipboard.
class HtmlMarkdownView extends StatelessWidget {
  const HtmlMarkdownView({
    super.key,
    required this.data,
    required this.onOpenLink,
    required this.style,
  });

  final String data;
  final ValueChanged<String> onOpenLink;
  final HtmlMarkdownStyle style;

  @override
  Widget build(BuildContext context) => platform.buildHtmlMarkdownView(
      data: data, onOpenLink: onOpenLink, style: style);
}

/// Theme tokens forwarded to the DOM as CSS custom properties.
@immutable
class HtmlMarkdownStyle {
  const HtmlMarkdownStyle({
    required this.text,
    required this.muted,
    required this.link,
    required this.border,
    required this.codeBackground,
    required this.fontSize,
    required this.syntaxKeyword,
    required this.syntaxString,
    required this.syntaxNumber,
    required this.syntaxTitle,
  });

  final Color text;
  final Color muted;
  final Color link;
  final Color border;
  final Color codeBackground;
  final double fontSize;
  final Color syntaxKeyword;
  final Color syntaxString;
  final Color syntaxNumber;
  final Color syntaxTitle;

  Map<String, String> toCssVariables() => {
        '--smd-text': _css(text),
        '--smd-muted': _css(muted),
        '--smd-link': _css(link),
        '--smd-border': _css(border),
        '--smd-code-bg': _css(codeBackground),
        '--smd-font-size': '${fontSize}px',
        '--smd-kw': _css(syntaxKeyword),
        '--smd-str': _css(syntaxString),
        '--smd-num': _css(syntaxNumber),
        '--smd-ttl': _css(syntaxTitle),
      };

  static String _css(Color c) =>
      'rgba(${(c.r * 255).round()},${(c.g * 255).round()},'
      '${(c.b * 255).round()},${c.a.toStringAsFixed(3)})';

  @override
  bool operator ==(Object other) =>
      other is HtmlMarkdownStyle &&
      other.toCssVariables().toString() == toCssVariables().toString();

  @override
  int get hashCode => toCssVariables().toString().hashCode;
}
