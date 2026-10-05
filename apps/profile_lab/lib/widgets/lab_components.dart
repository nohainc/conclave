import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/profile_lab_security.dart';
import '../theme/profile_lab_theme.dart';

class CopyMessageButton extends StatelessWidget {
  const CopyMessageButton(
      {super.key, required this.message, this.tooltip = 'Copy message'});
  final String message, tooltip;
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        icon: const Icon(Icons.copy_outlined, size: 18),
        onPressed: () async {
          await Clipboard.setData(
              ClipboardData(text: ProfileLabSecurity.redactSecrets(message)));
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)
                ?.showSnackBar(const SnackBar(content: Text('Message copied')));
          }
        },
      );
}

class CopyableMessage extends StatelessWidget {
  const CopyableMessage(this.message, {super.key, this.style});
  final String message;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: SelectableText(message, style: style)),
        CopyMessageButton(message: message),
      ]);
}

/// Shared geometry and semantic states for the Profile Lab desktop UI.
abstract final class LabSpace {
  static const small = 8.0;
  static const medium = 16.0;
  static const page = 24.0;
  static const row = 48.0;
}

enum LabStatus { neutral, success, warning, error }

class LabPageHeader extends StatelessWidget {
  const LabPageHeader(
      {super.key,
      required this.title,
      this.description,
      this.actions = const []});
  final String title;
  final String? description;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions)
            ]),
        if (description != null)
          Padding(
              padding: const EdgeInsets.only(top: 8), child: Text(description!))
      ]);
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(
      {super.key,
      required this.label,
      this.status = LabStatus.neutral,
      this.icon});
  final String label;
  final LabStatus status;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      LabStatus.success => ProfileLabTheme.passColor,
      LabStatus.warning => ProfileLabTheme.warnColor,
      LabStatus.error => ProfileLabTheme.failColor,
      LabStatus.neutral => ProfileLabTheme.secondaryText
    };
    final symbol = icon ??
        switch (status) {
          LabStatus.success => Icons.check_circle_outline,
          LabStatus.warning => Icons.warning_amber,
          LabStatus.error => Icons.error_outline,
          LabStatus.neutral => Icons.info_outline
        };
    return Semantics(
        container: true,
        label: label,
        child: ExcludeSemantics(
            child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(6)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(symbol, size: 16, color: color),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(label,
                          style: TextStyle(color: color, fontSize: 12)))
                ]))));
  }
}

class LabLifecycleStep {
  const LabLifecycleStep(this.title,
      {this.isDone = false, this.isActive = false});
  final String title;
  final bool isDone, isActive;
}

class LifecycleStepper extends StatelessWidget {
  const LifecycleStepper({super.key, required this.steps});
  final List<LabLifecycleStep> steps;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(LabSpace.medium),
          child: Wrap(spacing: 16, runSpacing: 12, children: [
            for (final step in steps)
              Semantics(
                  container: true,
                  label:
                      '${step.title}: ${step.isDone ? 'Complete' : step.isActive ? 'Current step' : 'Pending'}',
                  child: ExcludeSemantics(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        step.isDone
                            ? Icons.check_circle_outline
                            : step.isActive
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                        color: step.isDone
                            ? ProfileLabTheme.passColor
                            : step.isActive
                                ? ProfileLabTheme.primaryAccent
                                : ProfileLabTheme.secondaryText,
                        size: 18),
                    const SizedBox(width: 8),
                    Text(step.title)
                  ])))
          ])));
}

class EmptyState extends StatelessWidget {
  const EmptyState(
      {super.key,
      required this.title,
      this.description,
      this.action,
      this.icon = Icons.inbox_outlined});
  final String title;
  final String? description;
  final Widget? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(LabSpace.page),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 32, color: ProfileLabTheme.secondaryText),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            if (description != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(description!, textAlign: TextAlign.center)),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 16), child: action!)
          ])));
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(LabSpace.medium),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.error_outline,
                              color: ProfileLabTheme.failColor),
                          const SizedBox(width: 8),
                          Expanded(child: CopyableMessage(message))
                        ]),
                    if (onRetry != null)
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: onRetry,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry')))
                  ]))));
}

class WorkerSidebarItem extends StatelessWidget {
  const WorkerSidebarItem(
      {super.key,
      required this.name,
      required this.identity,
      required this.profileStatus,
      required this.catalogStage,
      required this.selected,
      required this.onTap});
  final String name, identity, profileStatus, catalogStage;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
      selected: selected,
      child: Material(
          color: ProfileLabTheme.darkSurface,
          child: ListTile(
              selected: selected,
              selectedColor: Colors.white,
              minVerticalPadding: 12,
              selectedTileColor:
                  ProfileLabTheme.primaryAccent.withValues(alpha: 0.12),
              leading: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? ProfileLabTheme.primaryAccent
                      : ProfileLabTheme.secondaryText),
              title: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identity, style: ProfileLabTheme.monoStyle),
                    Text('Profile: $profileStatus'),
                    Text('Catalog stage: $catalogStage')
                  ]),
              onTap: onTap)));
}

class PrimaryActionCard extends StatelessWidget {
  const PrimaryActionCard(
      {super.key,
      required this.title,
      required this.description,
      required this.actionLabel,
      required this.onPressed,
      this.status});
  final String title, description, actionLabel;
  final VoidCallback? onPressed;
  final Widget? status;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(LabSpace.medium),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Next step'),
                  if (status != null) status!
                ]),
            const SizedBox(height: LabSpace.small),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: LabSpace.small),
            Text(description),
            const SizedBox(height: 16),
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    onPressed: onPressed,
                    label: Text(actionLabel)))
          ])));
}

class TechnicalInspector extends StatelessWidget {
  const TechnicalInspector(
      {super.key,
      this.title = 'Technical details',
      this.subtitle,
      required this.children});
  final String title;
  final Widget? subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
          title: Text(title),
          subtitle: subtitle,
          childrenPadding: const EdgeInsets.all(LabSpace.medium),
          children: children));
}

class ReleaseChannelCard extends StatelessWidget {
  const ReleaseChannelCard(
      {super.key, required this.channel, required this.version});
  final String channel;
  final String? version;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(LabSpace.medium),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.alt_route,
                  size: 18, color: ProfileLabTheme.secondaryText),
              const SizedBox(width: 8),
              Flexible(child: Text(channel))
            ]),
            const SizedBox(height: 12),
            Text(version ?? 'None',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: LabSpace.small),
            StatusBadge(
                label: version == null ? 'Unassigned' : 'Assigned',
                icon:
                    version == null ? Icons.remove_circle_outline : Icons.link)
          ])));
}

class OperationProgress extends StatelessWidget {
  const OperationProgress({super.key, required this.label, this.value});
  final String label;
  final double? value;
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      label: label,
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(label),
            const SizedBox(height: LabSpace.small),
            LinearProgressIndicator(value: value, semanticsLabel: label)
          ])));
}
