import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';

import 'speech_dictation.dart';

/// Mic toggle with a language menu that writes browser speech recognition into [controller] at
/// the cursor. The user reviews and sends the text; no audio leaves the page
/// through Syntila. Hidden when the browser has no speech recognition.
class DictationButton extends StatefulWidget {
  const DictationButton({
    super.key,
    required this.controller,
    required this.enabled,
    required this.color,
    this.dictation,
    this.onTextChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final Color color;

  /// Overrides the platform recognizer (tests).
  final SpeechDictation? dictation;

  /// Runs after dictated text is written (e.g. to refocus the input).
  final VoidCallback? onTextChanged;

  @override
  State<DictationButton> createState() => _DictationButtonState();
}

class _DictationButtonState extends State<DictationButton> {
  late final SpeechDictation _dictation =
      widget.dictation ?? createSpeechDictation();
  bool _listening = false;
  String _prefix = '';
  String _suffix = '';
  String? _written;
  late String? _language = _dictation.preferredLanguage;

  String get _activeLanguage => _language ?? _dictation.browserLanguage;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(covariant DictationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _stop();
    }
    if (!widget.enabled) _stop();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    if (_listening) _dictation.stop();
    super.dispose();
  }

  /// Sending, clearing, or typing during dictation ends the session so a
  /// late transcript never resurrects text the user already moved past.
  void _controllerChanged() {
    if (_listening && _written != null && widget.controller.text != _written) {
      _stop();
    }
  }

  void _stop() {
    if (!_listening) return;
    _dictation.stop();
    _listening = false;
    _written = null;
    if (mounted) setState(() {});
  }

  void _start() {
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = text.substring(0, start);
    _prefix =
        before.isEmpty || RegExp(r'\s$').hasMatch(before) ? before : '$before ';
    _suffix = text.substring(end);
    _written = null;
    setState(() => _listening = true);
    _dictation.start(
        language: _activeLanguage, onTranscript: _write, onEnd: _ended);
  }

  void _write(String transcript) {
    if (!_listening || !mounted || transcript.isEmpty) return;
    final inserted = _suffix.isEmpty || RegExp(r'^\s').hasMatch(_suffix)
        ? transcript
        : '$transcript ';
    final text = '$_prefix$inserted$_suffix';
    _written = text;
    widget.controller.value = TextEditingValue(
      text: text,
      selection:
          TextSelection.collapsed(offset: _prefix.length + transcript.length),
    );
    widget.onTextChanged?.call();
  }

  void _ended(String? error) {
    if (!mounted) return;
    final wasListening = _listening;
    setState(() {
      _listening = false;
      _written = null;
    });
    final message = switch (error) {
      'not-allowed' ||
      'service-not-allowed' =>
        'Microphone access is blocked. Allow it in your browser settings.',
      'audio-capture' => 'No microphone was found.',
      'network' => 'Speech recognition is unavailable right now.',
      null || 'no-speech' || 'aborted' => null,
      _ => 'Dictation stopped.',
    };
    if (wasListening && message != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _selectLanguage(String? language) {
    _stop();
    _dictation.preferredLanguage = language;
    setState(() => _language = language);
  }

  String _languageName(String tag) {
    for (final (code, name) in dictationLanguages) {
      if (code.toLowerCase() == tag.toLowerCase()) return name;
    }
    return tag;
  }

  Widget _languageMenu() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final code = _activeLanguage.split('-').first.toUpperCase();
    Widget item(String? tag, String label) => MenuItemButton(
          key: ValueKey('dictation-language-${tag ?? 'browser'}'),
          style: SyntilaMenuStyle.item(dark),
          leadingIcon: Icon(_language == tag ? Icons.check : null, size: 16),
          onPressed: () => _selectLanguage(tag),
          child: Text(label, style: SyntilaMenuStyle.textStyle),
        );
    return MenuAnchor(
      style: SyntilaMenuStyle.surface(dark, composer: true),
      menuChildren: [
        item(null,
            'Browser default (${_languageName(_dictation.browserLanguage)})'),
        for (final (tag, name) in dictationLanguages) item(tag, name),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Dictation language: ${_languageName(_activeLanguage)}',
        child: TextButton(
          key: const ValueKey('composer-dictation-language'),
          style: TextButton.styleFrom(
            foregroundColor: widget.color,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(6))),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle:
                const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          onPressed: widget.enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          child: Text(code),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_dictation.supported) return const SizedBox.shrink();
    final label = _listening ? 'Stop dictation' : 'Dictate';
    final mic = IconButton(
      key: const ValueKey('composer-dictation'),
      tooltip: label,
      isSelected: _listening,
      color: _listening ? Theme.of(context).colorScheme.error : widget.color,
      onPressed: widget.enabled ? (_listening ? _stop : _start) : null,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 34, height: 30),
      padding: EdgeInsets.zero,
      style:
          IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic_none,
          size: 18, semanticLabel: label),
    );
    // Language and mic share one outlined track, styled like the Chat/Work
    // workflow selector; the outline turns red while recording.
    final colors = Theme.of(context).colorScheme;
    final border = _listening ? colors.error : colors.outlineVariant;
    return Container(
      key: const ValueKey('composer-dictation-group'),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _languageMenu(),
        mic,
      ]),
    );
  }
}
