import 'package:flutter/material.dart';
import '../../brand.dart';

/// Streaming typing indicator showing AI synthesis in progress
class StreamingTypingIndicator extends StatelessWidget {
  const StreamingTypingIndicator({
    super.key,
    this.workerName,
    this.statusText = 'Synthesizing response...',
  });

  final String? workerName;
  final String statusText;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface;
    final borderColor = isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;
    final inkColor = isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Conclave Mark Avatar
          Container(
            width: 28,
            height: 28,
            decoration: ConclaveBrand.brandMark,
            alignment: Alignment.center,
            child: const Text(
              'C',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Bubble
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(14),
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              ),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (workerName != null && workerName!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: ConclaveBrand.accent.withValues(alpha: isDark ? 0.25 : 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      workerName!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ConclaveBrand.accent,
                      ),
                    ),
                  ),
                ],
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: inkColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDot(0.4),
                    _buildDot(0.7),
                    _buildDot(1.0),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(double opacity) {
    return Container(
      width: 4.5,
      height: 4.5,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: ConclaveBrand.accent.withValues(alpha: opacity),
        shape: BoxShape.circle,
      ),
    );
  }
}
