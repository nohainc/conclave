import 'package:flutter/material.dart';

import 'speech_dictation.dart';

/// Mic toggle that writes browser speech recognition into [controller] at
/// the cursor. The user reviews and sends the text; no audio leaves the page
/// through Conclave. Hidden when the browser has no speech recognition.
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
    _dictation.start(onTranscript: _write, onEnd: _ended);
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

  @override
  Widget build(BuildContext context) {
    if (!_dictation.supported) return const SizedBox.shrink();
    final label = _listening ? 'Stop dictation' : 'Dictate';
    return IconButton(
      key: const ValueKey('composer-dictation'),
      tooltip: label,
      isSelected: _listening,
      color: _listening ? Theme.of(context).colorScheme.error : widget.color,
      onPressed: widget.enabled ? (_listening ? _stop : _start) : null,
      icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.mic_none,
          size: 18, semanticLabel: label),
    );
  }
}
