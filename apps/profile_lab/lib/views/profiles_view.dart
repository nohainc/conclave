import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'drafts_view.dart';
import 'test_bench_view.dart';

/// The Profiles surface combines Profile draft editing and local test execution.
class ProfilesView extends StatefulWidget {
  const ProfilesView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<ProfilesView> createState() => _ProfilesViewState();
}

class _ProfilesViewState extends State<ProfilesView> {
  int _activeSubMode = 0; // 0: Split View, 1: Editor Only, 2: Test Bench Only

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return Column(
      children: [
        // Mode toggle bar
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            border: Border(bottom: BorderSide(color: Color(0xFF334155))),
          ),
          child: Row(
            children: [
              const Text(
                'PROFILE WORKBENCH',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: Color(0xFF94A3B8)),
              ),
              const SizedBox(width: 16),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                      value: 0,
                      label:
                          Text('Split View', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: 1,
                      label:
                          Text('Editor Only', style: TextStyle(fontSize: 11))),
                  ButtonSegment(
                      value: 2,
                      label: Text('Test Bench Only',
                          style: TextStyle(fontSize: 11))),
                ],
                selected: {_activeSubMode},
                onSelectionChanged: (set) {
                  setState(() {
                    _activeSubMode = set.first;
                  });
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              if (c.selectedDefinitionId != null)
                Text(
                  'Definition: ${c.selectedDefinitionId}',
                  style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11,
                      color: Color(0xFFCBD5E1)),
                ),
            ],
          ),
        ),

        // Body content
        Expanded(
          child: switch (_activeSubMode) {
            1 => DraftsView(controller: c),
            2 => TestBenchView(controller: c),
            _ => Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: DraftsView(controller: c),
                  ),
                  const VerticalDivider(
                      width: 1, thickness: 1, color: Color(0xFF334155)),
                  Expanded(
                    flex: 5,
                    child: TestBenchView(controller: c),
                  ),
                ],
              ),
          },
        ),
      ],
    );
  }
}
