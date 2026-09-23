import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../brand.dart';

/// Interactive Diff & Patch Viewer for code modifications and execution artifacts
class DiffViewer extends StatelessWidget {
  const DiffViewer({
    super.key,
    required this.filePath,
    required this.diffContent,
    this.oldCommit,
    this.newCommit,
  });

  final String filePath;
  final String diffContent;
  final String? oldCommit;
  final String? newCommit;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface;
    final borderColor = isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine;
    final inkColor = isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk;
    final mutedInk = isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;

    final lines = diffContent.split('\n');

    return Container(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightPaper,
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.difference_outlined,
                  size: 16,
                  color: ConclaveBrand.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filePath,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: inkColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (oldCommit != null && newCommit != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text(
                      '${oldCommit!.substring(0, oldCommit!.length.clamp(0, 7))} → ${newCommit!.substring(0, newCommit!.length.clamp(0, 7))}',
                      style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: mutedInk),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  tooltip: 'Copy diff',
                  splashRadius: 14,
                  color: mutedInk,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: diffContent));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Diff copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          // Diff Lines
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: lines.map((line) => _buildDiffLine(line, isDark)).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffLine(String line, bool isDark) {
    Color? bgColor;
    Color textColor;
    FontWeight fontWeight = FontWeight.normal;

    if (line.startsWith('+')) {
      bgColor = isDark ? ConclaveBrand.successWashDark.withValues(alpha: 0.4) : ConclaveBrand.successWash;
      textColor = isDark ? const Color(0xff86efac) : const Color(0xff15803d);
    } else if (line.startsWith('-')) {
      bgColor = isDark ? ConclaveBrand.errorWashDark.withValues(alpha: 0.4) : ConclaveBrand.errorWash;
      textColor = isDark ? const Color(0xfffca5a5) : const Color(0xffb91c1c);
    } else if (line.startsWith('@@')) {
      bgColor = isDark ? ConclaveBrand.accentWashDark.withValues(alpha: 0.4) : ConclaveBrand.accentWash;
      textColor = ConclaveBrand.accent;
      fontWeight = FontWeight.w600;
    } else {
      textColor = isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;
    }

    return Container(
      width: double.infinity,
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1.5),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.4,
          color: textColor,
          fontWeight: fontWeight,
        ),
      ),
    );
  }
}
