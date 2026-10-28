import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

import 'composer_metrics.dart';

/// Emoji grouped for the composer picker.
const emojiPickerCategories = <(String, IconData, List<String>)>[
  (
    'Smileys',
    Icons.sentiment_satisfied_alt_outlined,
    [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', //
      '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙',
      '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔',
      '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '😮‍💨',
      '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢',
      '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '🥸',
      '😎', '🤓', '🧐', '😕', '😟', '🙁', '😮', '😯', '😲', '😳',
      '🥺', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖',
      '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬',
      '😈', '👿', '💀', '💩', '🤡', '👻', '👽', '🤖', '😺', '😸',
    ],
  ),
  (
    'Gestures',
    Icons.waving_hand_outlined,
    [
      '👍', '👎', '👌', '🤌', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', //
      '👉', '👆', '👇', '☝️', '✋', '🤚', '🖐️', '🖖', '👋', '👏',
      '🙌', '👐', '🤲', '🙏', '🤝', '💪', '✍️', '🫡', '🫶', '👀',
    ],
  ),
  (
    'Hearts',
    Icons.favorite_border,
    [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', //
      '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '✨', '⭐',
      '🌟', '💫', '🔥', '💯', '🎉', '🎊', '🏆', '🥇', '✅', '❌',
    ],
  ),
  (
    'Objects',
    Icons.lightbulb_outline,
    [
      '💡', '🚀', '🛠️', '🔧', '🐛', '📌', '📎', '📝', '📄', '📊', //
      '📈', '📉', '🗂️', '📦', '🔒', '🔑', '⚙️', '🧪', '🧠', '💻',
      '⌨️', '🖥️', '📱', '☕', '🍕', '⏰', '⏳', '🔔', '📣', '💬',
    ],
  ),
];

/// Smile button that opens a popup grid of emoji; a tap inserts the emoji.
class EmojiPickerButton extends StatefulWidget {
  const EmojiPickerButton({
    super.key,
    required this.onSelected,
    this.enabled = true,
    this.color,
  });

  final ValueChanged<String> onSelected;
  final bool enabled;
  final Color? color;

  @override
  State<EmojiPickerButton> createState() => _EmojiPickerButtonState();
}

class _EmojiPickerButtonState extends State<EmojiPickerButton> {
  final _menu = MenuController();
  var _category = 0;

  @override
  Widget build(BuildContext context) => MenuAnchor(
        controller: _menu,
        style: SyntilaMenuStyle.surface(
            Theme.of(context).brightness == Brightness.dark,
            composer: true),
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          StatefulBuilder(
            builder: (context, setMenuState) {
              final (_, _, emoji) = emojiPickerCategories[_category];
              return SizedBox(
                key: const ValueKey('emoji-picker'),
                width: 320,
                height: 300,
                child: Column(
                  children: [
                    Row(children: [
                      for (final (index, (label, icon, _))
                          in emojiPickerCategories.indexed)
                        IconButton(
                          tooltip: label,
                          isSelected: index == _category,
                          icon: Icon(icon, size: 18),
                          onPressed: () =>
                              setMenuState(() => _category = index),
                        ),
                    ]),
                    const Divider(height: 1),
                    Expanded(
                      child: GridView.count(
                        primary: false,
                        crossAxisCount: 8,
                        padding: const EdgeInsets.all(6),
                        children: [
                          for (final value in emoji)
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () {
                                widget.onSelected(value);
                                _menu.close();
                              },
                              child: Center(
                                child: Text(value,
                                    style: const TextStyle(fontSize: 22)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
        builder: (context, controller, _) => IconButton(
          key: const ValueKey('emoji-picker-button'),
          tooltip: 'Insert emoji',
          padding: EdgeInsets.zero,
          constraints: composerButtonConstraints,
          style: composerIconButtonStyle(),
          icon: Icon(Icons.sentiment_satisfied_alt_outlined,
              size: composerIconSize,
              color: widget.color,
              semanticLabel: 'Insert emoji'),
          onPressed: widget.enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        ),
      );
}

/// Inserts [text] at the cursor (replacing any selection).
void insertAtCursor(TextEditingController controller, String text) {
  final value = controller.value;
  final selection = value.selection;
  final start = selection.isValid ? selection.start : value.text.length;
  final end = selection.isValid ? selection.end : value.text.length;
  controller.value = TextEditingValue(
    text: value.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}
