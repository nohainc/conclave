import 'package:flutter/material.dart';

class WorkspaceSettingsPage extends StatelessWidget {
  const WorkspaceSettingsPage({super.key, required this.workspaceName});

  final String workspaceName;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const Text('Workspace settings',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Manage the active Workspace and its access.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Active Workspace',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  const Text(
                      'Workspace membership and permissions are managed in Conclave Cloud.',
                      style: TextStyle(color: Color(0xff777683))),
                  const SizedBox(height: 16),
                  Text(workspaceName),
                ],
              ),
            ),
          ),
        ],
      );
}
