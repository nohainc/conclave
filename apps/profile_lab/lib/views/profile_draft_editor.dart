import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syntila_design/syntila_design.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import '../utils/profile_lab_security.dart';

/// Schema-aware Tool Profile v1 candidate editor with live validation,
/// structured summary panels, compare, and recovery options.
class ProfileDraftEditor extends StatefulWidget {
  const ProfileDraftEditor({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<ProfileDraftEditor> createState() => _ProfileDraftEditorState();
}

class _ProfileDraftEditorState extends State<ProfileDraftEditor> {
  late _JsonCodeEditingController _textController;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _editorFocusNode = FocusNode();
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final Map<String, TextEditingValue> _workerEditorValues = {};
  final Map<String, double> _workerScrollOffsets = {};
  late String _activeWorkerKey;
  String _lastControllerText = '';
  bool _restorePending = false;
  bool _showFindReplace = false;
  bool _replaceVisible = false;

  String _workerKey(ProfileLabController controller) =>
      controller.selectedCloudWorker?['workerTypeId'] as String? ??
      controller.selectedDefinitionId ??
      'unselected';

  @override
  void initState() {
    super.initState();
    _activeWorkerKey = _workerKey(widget.controller);
    _textController = _JsonCodeEditingController(
      text: widget.controller.currentJsonText,
    );
    _lastControllerText = widget.controller.currentJsonText;
  }

  @override
  void didUpdateWidget(ProfileDraftEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextWorkerKey = _workerKey(widget.controller);
    if (nextWorkerKey != _activeWorkerKey) {
      _workerEditorValues[_activeWorkerKey] = _textController.value;
      _workerScrollOffsets[_activeWorkerKey] =
          _scrollController.hasClients ? _scrollController.offset : 0;
      _activeWorkerKey = nextWorkerKey;
      final saved = _workerEditorValues[nextWorkerKey];
      if (saved != null) {
        _textController.value = saved;
        _restorePending = true;
      } else {
        _textController.text = widget.controller.currentJsonText;
        _lastControllerText = widget.controller.currentJsonText;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final offset = _workerScrollOffsets[nextWorkerKey] ?? 0;
        _scrollController.jumpTo(
          offset
              .clamp(0.0, _scrollController.position.maxScrollExtent)
              .toDouble(),
        );
      });
      return;
    }
    if (_restorePending) {
      if (widget.controller.currentJsonText != _textController.text) {
        widget.controller.updateJsonText(_textController.text);
      }
      _restorePending = false;
      _lastControllerText = _textController.text;
      return;
    }
    if (widget.controller.currentJsonText != _lastControllerText &&
        _textController.text != widget.controller.currentJsonText) {
      _textController.text = widget.controller.currentJsonText;
      _lastControllerText = widget.controller.currentJsonText;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  void _openFindReplace({bool replace = false}) {
    setState(() {
      _showFindReplace = true;
      _replaceVisible = replace;
    });
    _editorFocusNode.requestFocus();
  }

  void _closeFindReplace() {
    setState(() => _showFindReplace = false);
    _editorFocusNode.requestFocus();
  }

  void _findNext() {
    final query = _findController.text;
    if (query.isEmpty) return;
    final text = _textController.text;
    final start = _textController.selection.extentOffset.clamp(0, text.length);
    final next = text.indexOf(query, start);
    final match = next >= 0 ? next : text.indexOf(query);
    if (match < 0) return;
    _textController.selection = TextSelection(
      baseOffset: match,
      extentOffset: match + query.length,
    );
    _editorFocusNode.requestFocus();
  }

  void _replaceNext() {
    final query = _findController.text;
    if (query.isEmpty) return;
    final selection = _textController.selection;
    if (_textController.text.substring(selection.start, selection.end) ==
        query) {
      final replacement = _replaceController.text;
      _textController.value = _textController.value.copyWith(
        text: _textController.text.replaceRange(
          selection.start,
          selection.end,
          replacement,
        ),
        selection: TextSelection.collapsed(
          offset: selection.start + replacement.length,
        ),
      );
      _lastControllerText = _textController.text;
      widget.controller.updateJsonText(_textController.text);
    }
    _findNext();
  }

  void _replaceAll() {
    final query = _findController.text;
    if (query.isEmpty) return;
    final replacement = _replaceController.text;
    final updated = _textController.text.replaceAll(query, replacement);
    if (updated == _textController.text) return;
    _textController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: updated.length),
    );
    _lastControllerText = updated;
    widget.controller.updateJsonText(updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return Row(
      children: [
        // Main Editor Surface
        Expanded(
          child: c.currentDraft == null
              ? const Center(
                  child: Text(
                      'Select or create a candidate to begin authoring.',
                      style: TextStyle(
                          fontSize: 13, color: ProfileLabTheme.secondaryText)))
              : LayoutBuilder(
                  builder: (context, layout) => Column(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                                maxHeight: layout.maxHeight * 0.4),
                            child: SingleChildScrollView(
                                child: Column(children: [
                              // Continuous Validation Diagnostics Banner
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: c.jsonValidationError == null
                                      ? ProfileLabTheme.passColor
                                          .withValues(alpha: 0.12)
                                      : ProfileLabTheme.failColor
                                          .withValues(alpha: 0.15),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: c.jsonValidationError == null
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      c.jsonValidationError == null
                                          ? Icons.check_circle_outline
                                          : Icons.error_outline,
                                      color: c.jsonValidationError == null
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        c.jsonValidationError == null
                                            ? 'JSON valid · Tool Profile schema ready'
                                            : 'Invalid JSON${c.jsonValidationLocation == null ? '' : ' · ${c.jsonValidationLocation}'} · ${c.jsonValidationError}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: c.jsonValidationError == null
                                              ? ProfileLabTheme.passColor
                                              : ProfileLabTheme.failColor,
                                        ),
                                      ),
                                    ),
                                    if (c.jsonValidationError != null) ...[
                                      const SizedBox(width: 8),
                                      IconButton(
                                        key: const Key(
                                            'copy-json-validation-error'),
                                        tooltip: 'Copy validation error',
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.copy,
                                          size: 16,
                                          color: ProfileLabTheme.failColor,
                                        ),
                                        onPressed: () async {
                                          final text =
                                              'Invalid JSON${c.jsonValidationLocation == null ? '' : ' · ${c.jsonValidationLocation}'} · ${c.jsonValidationError}';
                                          await Clipboard.setData(
                                            ClipboardData(
                                              text: ProfileLabSecurity
                                                  .redactSecrets(text),
                                            ),
                                          );
                                          if (!context.mounted) return;
                                          final m =
                                              ScaffoldMessenger.of(context);
                                          m.hideCurrentSnackBar();
                                          m.showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                  'Validation error copied'),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ])),
                          ),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final editor = Container(
                                  key: const ValueKey('profile-json-editor'),
                                  color: ProfileLabTheme.darkBackground,
                                  child: Column(
                                    children: [
                                      if (_showFindReplace)
                                        _FindReplaceBar(
                                          findController: _findController,
                                          replaceController: _replaceController,
                                          replaceVisible: _replaceVisible,
                                          onClose: _closeFindReplace,
                                          onFindNext: _findNext,
                                          onReplaceNext: _replaceNext,
                                          onReplaceAll: _replaceAll,
                                          onToggleReplace: () => setState(() {
                                            _replaceVisible = !_replaceVisible;
                                          }),
                                        ),
                                      Expanded(
                                        child: Shortcuts(
                                          shortcuts: <ShortcutActivator,
                                              Intent>{
                                            const SingleActivator(
                                              LogicalKeyboardKey.keyF,
                                              meta: true,
                                            ): const _FindIntent(),
                                            const SingleActivator(
                                              LogicalKeyboardKey.keyF,
                                              control: true,
                                            ): const _FindIntent(),
                                            const SingleActivator(
                                              LogicalKeyboardKey.keyH,
                                              meta: true,
                                            ): const _ReplaceIntent(),
                                            const SingleActivator(
                                              LogicalKeyboardKey.keyH,
                                              control: true,
                                            ): const _ReplaceIntent(),
                                          },
                                          child: Actions(
                                            actions: <Type, Action<Intent>>{
                                              _FindIntent: CallbackAction(
                                                onInvoke: (_) {
                                                  _openFindReplace();
                                                  return null;
                                                },
                                              ),
                                              _ReplaceIntent: CallbackAction(
                                                onInvoke: (_) {
                                                  _openFindReplace(
                                                      replace: true);
                                                  return null;
                                                },
                                              ),
                                            },
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                _LineNumberGutter(
                                                  controller: _textController,
                                                  scrollController:
                                                      _scrollController,
                                                ),
                                                Expanded(
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            right: 16,
                                                            top: 10,
                                                            bottom: 10),
                                                    child: EditableText(
                                                      key: const ValueKey(
                                                          'profile-json-input'),
                                                      controller:
                                                          _textController,
                                                      focusNode:
                                                          _editorFocusNode,
                                                      scrollController:
                                                          _scrollController,
                                                      maxLines: null,
                                                      expands: true,
                                                      keyboardType:
                                                          TextInputType
                                                              .multiline,
                                                      textInputAction:
                                                          TextInputAction
                                                              .newline,
                                                      inputFormatters: const [
                                                        _JsonIndentFormatter(),
                                                      ],
                                                      style: ProfileLabTheme
                                                          .monoStyle
                                                          .copyWith(
                                                        fontSize: 12,
                                                        height: 1.5,
                                                      ),
                                                      cursorColor:
                                                          ProfileLabTheme
                                                              .primaryAccent,
                                                      selectionColor:
                                                          ProfileLabTheme
                                                              .primaryAccent
                                                              .withValues(
                                                                  alpha: 0.25),
                                                      backgroundCursorColor:
                                                          ProfileLabTheme
                                                              .primaryAccent,
                                                      onChanged: (value) {
                                                        _lastControllerText =
                                                            value;
                                                        c.updateJsonText(value);
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      _EditorStatusBar(
                                        controller: _textController,
                                        profileController: c,
                                      ),
                                    ],
                                  ),
                                );
                                return editor;
                              },
                            ),
                          ),
                        ],
                      )),
        ),
      ],
    );
  }
}

class _FindIntent extends Intent {
  const _FindIntent();
}

class _ReplaceIntent extends Intent {
  const _ReplaceIntent();
}

/// A small JSON editor built on Flutter's maintained EditableText primitive.
///
/// Keeping the editing surface on Flutter primitives avoids a native macOS
/// embedding dependency while retaining platform undo/redo, selection,
/// accessibility, and text-input behavior.
class _JsonCodeEditingController extends TextEditingController {
  _JsonCodeEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final matching = _matchingBrackets(text);
    final caret = selection.extentOffset;
    final activeBracket = matching[caret] ?? matching[caret - 1];
    final children = <TextSpan>[];
    var index = 0;
    while (index < text.length) {
      final character = text[index];
      if (character == '"') {
        var end = index + 1;
        var escaped = false;
        while (end < text.length) {
          final current = text[end];
          if (current == '"' && !escaped) {
            end++;
            break;
          }
          escaped = current == '\\' && !escaped;
          if (current != '\\') escaped = false;
          end++;
        }
        var after = end;
        while (after < text.length &&
            (text[after] == ' ' || text[after] == '\t')) {
          after++;
        }
        final isKey = after < text.length && text[after] == ':';
        children.add(TextSpan(
          text: text.substring(index, end),
          style: base.copyWith(
            color: isKey
                ? ProfileLabTheme.primaryAccent
                : SyntilaColors.syntaxStringDark,
          ),
        ));
        index = end;
        continue;
      }
      if ('{}[]'.contains(character)) {
        children.add(TextSpan(
          text: character,
          style: base.copyWith(
            color: activeBracket == index
                ? Colors.white
                : SyntilaColors.syntaxBracketDark,
            fontWeight:
                activeBracket == index ? FontWeight.bold : FontWeight.normal,
            backgroundColor: activeBracket == index
                ? ProfileLabTheme.primaryAccent.withValues(alpha: 0.28)
                : null,
          ),
        ));
        index++;
        continue;
      }
      if (RegExp(r'[-0-9]').hasMatch(character)) {
        final match =
            RegExp(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
                .matchAsPrefix(text, index);
        if (match != null) {
          children.add(TextSpan(
            text: match.group(0),
            style: base.copyWith(color: SyntilaColors.syntaxKeywordDark),
          ));
          index = match.end;
          continue;
        }
      }
      final literal = RegExp(r'(true|false|null)').matchAsPrefix(text, index);
      if (literal != null) {
        children.add(TextSpan(
          text: literal.group(0),
          style: base.copyWith(color: SyntilaColors.syntaxNumberDark),
        ));
        index = literal.end;
        continue;
      }
      children.add(TextSpan(text: character, style: base));
      index++;
    }
    return TextSpan(style: base, children: children);
  }

  Map<int, int> _matchingBrackets(String value) {
    const opens = '{[';
    final stack = <int>[];
    final pairs = <int, int>{};
    var inString = false;
    var escaped = false;
    for (var index = 0; index < value.length; index++) {
      final character = value[index];
      if (character == '"' && !escaped) inString = !inString;
      if (inString) {
        escaped = character == '\\' && !escaped;
        if (character != '\\') escaped = false;
        continue;
      }
      escaped = false;
      if (opens.contains(character)) {
        stack.add(index);
      } else if (character == '}' || character == ']') {
        final expected = character == '}' ? '{' : '[';
        if (stack.isNotEmpty && value[stack.last] == expected) {
          final opening = stack.removeLast();
          pairs[opening] = index;
          pairs[index] = opening;
        }
      }
    }
    return pairs;
  }
}

class _JsonIndentFormatter extends TextInputFormatter {
  const _JsonIndentFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final caret = newValue.selection.extentOffset;
    if (caret <= 0 || caret > newValue.text.length) return newValue;
    if (newValue.text[caret - 1] != '\n') return newValue;
    final lineStart = newValue.text.lastIndexOf('\n', caret - 2) + 1;
    final previousLine = newValue.text.substring(lineStart, caret - 1);
    final leading = RegExp(r'^\s*').firstMatch(previousLine)?.group(0) ?? '';
    final trimmed = previousLine.trimRight();
    final indent =
        leading + (trimmed.endsWith('{') || trimmed.endsWith('[') ? '  ' : '');
    if (indent.isEmpty) return newValue;
    final updated = newValue.text.replaceRange(caret, caret, indent);
    return newValue.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: caret + indent.length),
      composing: TextRange.empty,
    );
  }
}

class _LineNumberGutter extends StatelessWidget {
  const _LineNumberGutter({
    required this.controller,
    required this.scrollController,
  });

  final _JsonCodeEditingController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, scrollController]),
      builder: (context, _) => CustomPaint(
        painter: _LineNumberPainter(
          lineCount: '\n'.allMatches(controller.text).length + 1,
          scrollOffset:
              scrollController.hasClients ? scrollController.offset : 0,
        ),
        child: const SizedBox(width: 48),
      ),
    );
  }
}

class _LineNumberPainter extends CustomPainter {
  const _LineNumberPainter({
    required this.lineCount,
    required this.scrollOffset,
  });

  final int lineCount;
  final double scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final textStyle = ProfileLabTheme.monoStyle.copyWith(
      color: ProfileLabTheme.secondaryText,
      fontSize: 12,
      height: 1.5,
    );
    final lineHeight = 18.0;
    canvas.clipRect(Offset.zero & size);
    for (var line = 0; line < lineCount; line++) {
      final y = 10 + line * lineHeight - scrollOffset;
      if (y < -lineHeight || y > size.height) continue;
      final painter = TextPainter(
        text: TextSpan(text: '${line + 1}', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: size.width - 10);
      painter.paint(canvas, Offset(size.width - painter.width - 10, y));
    }
  }

  @override
  bool shouldRepaint(_LineNumberPainter oldDelegate) =>
      oldDelegate.lineCount != lineCount ||
      oldDelegate.scrollOffset != scrollOffset;
}

class _EditorStatusBar extends StatelessWidget {
  const _EditorStatusBar({
    required this.controller,
    required this.profileController,
  });

  final _JsonCodeEditingController controller;
  final ProfileLabController profileController;

  @override
  Widget build(BuildContext context) {
    final rawOffset = controller.selection.extentOffset;
    final offset =
        rawOffset < 0 ? 0 : rawOffset.clamp(0, controller.text.length).toInt();
    final line =
        '\n'.allMatches(controller.text.substring(0, offset)).length + 1;
    final lineStart =
        offset == 0 ? 0 : controller.text.lastIndexOf('\n', offset - 1) + 1;
    final column = offset - lineStart + 1;
    final error = profileController.jsonValidationLocation;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        border: Border(top: BorderSide(color: ProfileLabTheme.borderColor)),
      ),
      child: Row(
        children: [
          Text(
            error == null ? 'JSON · UTF-8' : 'Syntax error · $error',
            style: TextStyle(
              color: error == null
                  ? ProfileLabTheme.secondaryText
                  : ProfileLabTheme.failColor,
              fontSize: 11,
            ),
          ),
          const Spacer(),
          Text(
            'Ln $line, Col $column',
            style: const TextStyle(
              color: ProfileLabTheme.secondaryText,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _FindReplaceBar extends StatelessWidget {
  const _FindReplaceBar({
    required this.findController,
    required this.replaceController,
    required this.replaceVisible,
    required this.onClose,
    required this.onFindNext,
    required this.onReplaceNext,
    required this.onReplaceAll,
    required this.onToggleReplace,
  });

  final TextEditingController findController;
  final TextEditingController replaceController;
  final bool replaceVisible;
  final VoidCallback onClose;
  final VoidCallback onFindNext;
  final VoidCallback onReplaceNext;
  final VoidCallback onReplaceAll;
  final VoidCallback onToggleReplace;

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      SizedBox(
        width: 220,
        child: TextField(
          controller: findController,
          autofocus: true,
          onSubmitted: (_) => onFindNext(),
          decoration: const InputDecoration(
            hintText: 'Find',
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 16),
          ),
        ),
      ),
      if (replaceVisible)
        SizedBox(
          width: 220,
          child: TextField(
            controller: replaceController,
            onSubmitted: (_) => onReplaceNext(),
            decoration: const InputDecoration(
              hintText: 'Replace',
              isDense: true,
            ),
          ),
        ),
      IconButton(
        tooltip: 'Find next',
        icon: const Icon(Icons.arrow_downward, size: 16),
        onPressed: onFindNext,
      ),
      IconButton(
        tooltip: replaceVisible ? 'Hide replace' : 'Show replace',
        icon: const Icon(Icons.find_replace, size: 16),
        onPressed: onToggleReplace,
      ),
      if (replaceVisible) ...[
        TextButton(onPressed: onReplaceNext, child: const Text('Replace')),
        TextButton(onPressed: onReplaceAll, child: const Text('All')),
      ],
      IconButton(
        tooltip: 'Close search',
        icon: const Icon(Icons.close, size: 16),
        onPressed: onClose,
      ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      decoration: const BoxDecoration(
        color: ProfileLabTheme.darkSurface,
        border: Border(bottom: BorderSide(color: ProfileLabTheme.borderColor)),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: fields,
      ),
    );
  }
}
