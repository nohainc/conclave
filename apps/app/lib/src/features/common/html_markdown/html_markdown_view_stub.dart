import 'package:flutter/widgets.dart';

import 'html_markdown_view.dart';

const bool htmlMarkdownSupported = false;

Widget buildHtmlMarkdownView({
  required String data,
  required ValueChanged<String> onOpenLink,
  required HtmlMarkdownStyle style,
}) =>
    throw UnsupportedError('HTML Markdown requires Flutter Web.');
