import 'package:syntila_design/syntila_design.dart';
import 'quiet_notices.dart';
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
    final surfaceColor =
        isDark ? SyntilaBrand.darkSurface : SyntilaBrand.lightSurface;
    final borderColor =
        isDark ? SyntilaBrand.darkLine : SyntilaBrand.lightLine;
    final inkColor = isDark ? SyntilaBrand.darkInk : SyntilaBrand.lightInk;
    final mutedInk =
        isDark ? SyntilaBrand.darkInkMuted : SyntilaBrand.lightInkMuted;

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
              color:
                  isDark ? SyntilaBrand.darkPaper : SyntilaBrand.lightPaper,
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.difference_outlined,
                  size: 16,
                  color: SyntilaBrand.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    filePath,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFamily: SyntilaTypography.fontFamilyMono,
                      fontFamilyFallback:
                          SyntilaTypography.fontFamilyMonoFallback,
                      color: inkColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (oldCommit != null && newCommit != null) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDark
                          ? SyntilaBrand.darkSurface
                          : SyntilaBrand.lightSurface,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text(
                      '${oldCommit!.substring(0, oldCommit!.length.clamp(0, 7))} → ${newCommit!.substring(0, newCommit!.length.clamp(0, 7))}',
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: SyntilaTypography.fontFamilyMono,
                          fontFamilyFallback:
                              SyntilaTypography.fontFamilyMonoFallback,
                          color: mutedInk),
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
                    ScaffoldMessenger.of(context).showNotice(
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
                children:
                    lines.map((line) => _buildDiffLine(line, isDark)).toList(),
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
      bgColor = isDark
          ? SyntilaBrand.successWashDark.withValues(alpha: 0.4)
          : SyntilaBrand.successWash;
      textColor = SyntilaColors.successText(isDark);
    } else if (line.startsWith('-')) {
      bgColor = isDark
          ? SyntilaBrand.errorWashDark.withValues(alpha: 0.4)
          : SyntilaBrand.errorWash;
      textColor = SyntilaColors.errorText(isDark);
    } else if (line.startsWith('@@')) {
      bgColor = isDark
          ? SyntilaBrand.accentWashDark.withValues(alpha: 0.4)
          : SyntilaBrand.accentWash;
      textColor = SyntilaBrand.accent;
      fontWeight = FontWeight.w600;
    } else {
      textColor =
          isDark ? SyntilaBrand.darkInkMuted : SyntilaBrand.lightInkMuted;
    }

    return Container(
      width: double.infinity,
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1.5),
      child: Text(
        line.isEmpty ? ' ' : line,
        style: TextStyle(
          fontFamily: SyntilaTypography.fontFamilyMono,
          fontFamilyFallback: SyntilaTypography.fontFamilyMonoFallback,
          fontSize: 12,
          height: 1.4,
          color: textColor,
          fontWeight: fontWeight,
        ),
      ),
    );
  }
}
