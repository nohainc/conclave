import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../brand.dart';
import '../../studio/studio_models.dart';

/// Ergonomic chat prompt composer with multiline support and execution controls
class PromptComposer extends StatefulWidget {
  const PromptComposer({
    super.key,
    required this.controller,
    required this.onSubmitted,
    required this.selectedQuality,
    required this.onQualityChanged,
    required this.selectedWorker,
    required this.onWorkerChanged,
    required this.selectedModel,
    required this.onModelChanged,
    required this.selectedAccount,
    required this.onAccountChanged,
    required this.selectedHost,
    required this.onHostChanged,
    required this.showAdvanced,
    required this.onToggleAdvanced,
    required this.snapshot,
    this.isBusy = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final StudioQualityPreset selectedQuality;
  final ValueChanged<StudioQualityPreset> onQualityChanged;
  final String selectedWorker;
  final ValueChanged<String> onWorkerChanged;
  final String selectedModel;
  final ValueChanged<String> onModelChanged;
  final String selectedAccount;
  final ValueChanged<String> onAccountChanged;
  final String selectedHost;
  final ValueChanged<String> onHostChanged;
  final bool showAdvanced;
  final VoidCallback onToggleAdvanced;
  final StudioSnapshot snapshot;
  final bool isBusy;

  @override
  State<PromptComposer> createState() => _PromptComposerState();
}

class _PromptComposerState extends State<PromptComposer> {
  final FocusNode _focusNode = FocusNode();

  void _handleSubmit() {
    final text = widget.controller.text.trim();
    if (text.isNotEmpty && !widget.isBusy) {
      widget.onSubmitted(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface;
    final borderColor =
        isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Advanced Execution Options Panel (Expandable)
          if (widget.showAdvanced) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightPaper,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(13)),
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _DropdownSelector(
                    label: 'Worker',
                    value: widget.selectedWorker,
                    options: [
                      'Auto',
                      ...widget.snapshot.workers.map((w) => w.displayName)
                    ],
                    onChanged: (val) => widget.onWorkerChanged(val ?? 'Auto'),
                  ),
                  _DropdownSelector(
                    label: 'Model',
                    value: widget.selectedModel,
                    options: const [
                      'Auto',
                      'gpt-4o',
                      'claude-3-7-sonnet',
                      'claude-3-5-sonnet',
                      'gemini-2.0-flash'
                    ],
                    onChanged: (val) => widget.onModelChanged(val ?? 'Auto'),
                  ),
                  _DropdownSelector(
                    label: 'Account',
                    value: widget.selectedAccount,
                    options: [
                      'Auto',
                      ...widget.snapshot.accounts.map((a) => a.name)
                    ],
                    onChanged: (val) => widget.onAccountChanged(val ?? 'Auto'),
                  ),
                  _DropdownSelector(
                    label: 'Host',
                    value: widget.selectedHost,
                    options: [
                      'Auto',
                      ...widget.snapshot.hosts.map((h) => h.name)
                    ],
                    onChanged: (val) => widget.onHostChanged(val ?? 'Auto'),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? ConclaveBrand.darkSurface
                          : ConclaveBrand.lightSurface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: borderColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Candidates',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                        Text(
                          ': ${widget.snapshot.workers.length}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? ConclaveBrand.darkInkMuted
                                : ConclaveBrand.lightInkMuted,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Cost',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500),
                        ),
                        Text(
                          ': Auto',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? ConclaveBrand.darkInkMuted
                                : ConclaveBrand.lightInkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Prompt Text Input Field
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: (event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  _handleSubmit();
                }
              },
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                minLines: 1,
                maxLines: 6,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color:
                      isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Ask Conclave AX to research, design, code, or verify...',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: isDark
                        ? ConclaveBrand.darkInkMuted
                        : ConclaveBrand.lightInkMuted,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  filled: false,
                ),
              ),
            ),
          ),
          // Bottom Controls: Preset + Advanced Toggle + Send
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 8,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isDark
                            ? ConclaveBrand.darkPaper
                            : ConclaveBrand.lightPaper,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: borderColor),
                      ),
                      child: const Text(
                        'Auto',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    // Quality Preset Selector
                    PopupMenuButton<StudioQualityPreset>(
                      tooltip: 'Select quality preset',
                      initialValue: widget.selectedQuality,
                      onSelected: widget.onQualityChanged,
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: StudioQualityPreset.economy,
                          child: Text('Economy (Single Model)'),
                        ),
                        const PopupMenuItem(
                          value: StudioQualityPreset.balanced,
                          child: Text('Balanced (Standard)'),
                        ),
                        const PopupMenuItem(
                          value: StudioQualityPreset.highAssurance,
                          child: Text('High Assurance (Multi-Worker)'),
                        ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: isDark
                              ? ConclaveBrand.darkPaper
                              : ConclaveBrand.lightPaper,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: borderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.tune_rounded,
                                size: 14, color: ConclaveBrand.accent),
                            const SizedBox(width: 5),
                            Text(
                              widget.selectedQuality.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? ConclaveBrand.darkInk
                                    : ConclaveBrand.lightInk,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.arrow_drop_down_rounded,
                                size: 16,
                                color: isDark
                                    ? ConclaveBrand.darkInkMuted
                                    : ConclaveBrand.lightInkMuted),
                          ],
                        ),
                      ),
                    ),
                    // Advanced Execution Toggle Button
                    InkWell(
                      onTap: widget.onToggleAdvanced,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: widget.showAdvanced
                              ? (isDark
                                  ? ConclaveBrand.accentWashDark
                                  : ConclaveBrand.accentWash)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.showAdvanced
                                  ? Icons.tune_rounded
                                  : Icons.settings_outlined,
                              size: 14,
                              color: widget.showAdvanced
                                  ? ConclaveBrand.accent
                                  : (isDark
                                      ? ConclaveBrand.darkInkMuted
                                      : ConclaveBrand.lightInkMuted),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Advanced execution',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: widget.showAdvanced
                                    ? ConclaveBrand.accent
                                    : (isDark
                                        ? ConclaveBrand.darkInkMuted
                                        : ConclaveBrand.lightInkMuted),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                // Send Prompt Button
                IconButton.filled(
                  icon: widget.isBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.arrow_upward_rounded, size: 18),
                  tooltip: 'Send prompt (Enter)',
                  style: IconButton.styleFrom(
                    backgroundColor: ConclaveBrand.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: widget.isBusy ? null : _handleSubmit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownSelector extends StatelessWidget {
  const _DropdownSelector({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDark
                ? ConclaveBrand.darkInkMuted
                : ConclaveBrand.lightInkMuted,
          ),
        ),
        const Text(': '),
        DropdownButton<String>(
          value: options.contains(value) ? value : options.first,
          isDense: true,
          underline: const SizedBox.shrink(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
          ),
          items: options
              .map((opt) => DropdownMenuItem(value: opt, child: Text(opt)))
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
