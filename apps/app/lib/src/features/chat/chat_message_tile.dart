import 'package:flutter/material.dart';
import '../../brand.dart';
import '../../studio/studio_models.dart';
import '../common/code_block_view.dart';

/// Single chat message bubble with role indicator, avatar, and markdown rendering
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({
    super.key,
    required this.message,
  });

  final StudioChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUser = message.sender == StudioMessageSender.user;
    final isSystem = message.sender == StudioMessageSender.system;

    if (isSystem) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
        ),
        child: Text(
          message.content,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: ConclaveBrand.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.smart_toy_rounded, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? (isDark ? ConclaveBrand.accentDark : ConclaveBrand.accent)
                    : (isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isUser ? 14 : 2),
                  bottomRight: Radius.circular(isUser ? 2 : 14),
                ),
                border: isUser
                    ? null
                    : Border.all(color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isUser) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message.senderName,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: ConclaveBrand.accent,
                          ),
                        ),
                        if (message.senderRole.name.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: isDark ? ConclaveBrand.accentWashDark : ConclaveBrand.accentWash,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              message.senderRole.name.toUpperCase(),
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: ConclaveBrand.accent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  MarkdownMessageBody(
                    text: message.content,
                    textStyle: TextStyle(
                      fontSize: 13.5,
                      height: 1.45,
                      color: isUser
                          ? Colors.white
                          : (isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(message.sentAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: isUser
                          ? Colors.white.withValues(alpha: 0.7)
                          : (isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 10),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isDark ? ConclaveBrand.darkSurfaceHover : ConclaveBrand.lightSurfaceHover,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
              ),
              child: Icon(
                Icons.person_rounded,
                size: 16,
                color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(String time) {
    if (time.contains('T')) {
      final parsed = DateTime.tryParse(time);
      if (parsed != null) {
        final hour = parsed.hour.toString().padLeft(2, '0');
        final minute = parsed.minute.toString().padLeft(2, '0');
        return '$hour:$minute';
      }
    }
    return time;
  }
}
