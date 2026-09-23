import 'package:flutter/material.dart';
import '../../brand.dart';
import '../../studio/studio_models.dart';

/// Interactive visual pipeline / DAG showing task execution flow
class TaskPipelineDAG extends StatelessWidget {
  const TaskPipelineDAG({
    super.key,
    required this.tasks,
    required this.selectedTaskId,
    required this.onSelectTask,
  });

  final List<StudioTask> tasks;
  final String? selectedTaskId;
  final ValueChanged<String> onSelectTask;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'EXECUTION PIPELINE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                ),
              ),
              Row(
                children: [
                  const _StatusLegend(color: ConclaveBrand.success, label: 'Completed'),
                  const SizedBox(width: 12),
                  const _StatusLegend(color: ConclaveBrand.info, label: 'Running'),
                  const SizedBox(width: 12),
                  const _StatusLegend(color: ConclaveBrand.error, label: 'Failed'),
                  const SizedBox(width: 12),
                  _StatusLegend(color: isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine, label: 'Pending'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Horizontal scrolling DAG pipeline
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(tasks.length, (index) {
                final task = tasks[index];
                final isSelected = task.id == selectedTaskId;
                final isLast = index == tasks.length - 1;

                return Row(
                  children: [
                    _TaskNodeCard(
                      task: task,
                      isSelected: isSelected,
                      onTap: () => onSelectTask(task.id),
                    ),
                    if (!isLast) ...[
                      Container(
                        width: 28,
                        height: 2,
                        color: task.isCompleted
                            ? ConclaveBrand.success
                            : (isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: task.isCompleted
                            ? ConclaveBrand.success
                            : (isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted),
                      ),
                    ],
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLegend extends StatelessWidget {
  const _StatusLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: Theme.of(context).brightness == Brightness.dark
                ? ConclaveBrand.darkInkMuted
                : ConclaveBrand.lightInkMuted,
          ),
        ),
      ],
    );
  }
}

class _TaskNodeCard extends StatelessWidget {
  const _TaskNodeCard({
    required this.task,
    required this.isSelected,
    required this.onTap,
  });

  final StudioTask task;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Color borderColor;
    Color statusBgColor;
    IconData statusIcon;
    Color statusColor;

    if (task.isCompleted) {
      statusColor = ConclaveBrand.success;
      statusBgColor = isDark ? ConclaveBrand.successWashDark : ConclaveBrand.successWash;
      statusIcon = Icons.check_circle_rounded;
      borderColor = isSelected ? ConclaveBrand.accent : ConclaveBrand.success.withValues(alpha: 0.5);
    } else if (task.isRunning) {
      statusColor = ConclaveBrand.info;
      statusBgColor = isDark ? ConclaveBrand.infoWashDark : ConclaveBrand.infoWash;
      statusIcon = Icons.sync_rounded;
      borderColor = isSelected ? ConclaveBrand.accent : ConclaveBrand.info;
    } else if (task.isFailed) {
      statusColor = ConclaveBrand.error;
      statusBgColor = isDark ? ConclaveBrand.errorWashDark : ConclaveBrand.errorWash;
      statusIcon = Icons.error_rounded;
      borderColor = isSelected ? ConclaveBrand.accent : ConclaveBrand.error;
    } else {
      statusColor = isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;
      statusBgColor = isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightPaper;
      statusIcon = Icons.schedule_rounded;
      borderColor = isSelected ? ConclaveBrand.accent : (isDark ? ConclaveBrand.darkLine : ConclaveBrand.lightLine);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 180,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? ConclaveBrand.accentWashDark : ConclaveBrand.accentWash.withValues(alpha: 0.5))
              : (isDark ? ConclaveBrand.darkPaper : ConclaveBrand.lightSurface),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor, width: isSelected ? 2 : 1.2),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: ConclaveBrand.accent.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusBgColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, size: 11, color: statusColor),
                      const SizedBox(width: 3),
                      Text(
                        task.status.label.toUpperCase(),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    task.stage.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: 12,
                  color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    task.assignedWorkerId ?? 'Auto Worker',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
