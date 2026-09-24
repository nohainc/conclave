import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

/// AI Accounts tab displaying credential profiles and connection status.
class AccountsTab extends StatelessWidget {
  const AccountsTab({
    super.key,
    required this.accounts,
    this.onCreateAccount,
    this.onRequestAccountSetup,
    this.onRevokeAccount,
    this.workerActionMessage,
    this.onDismissWorkerActionMessage,
  });

  final List<StudioCredentialProfile> accounts;
  final VoidCallback? onCreateAccount;
  final ValueChanged<StudioCredentialProfile>? onRequestAccountSetup;
  final ValueChanged<StudioCredentialProfile>? onRevokeAccount;
  final String? workerActionMessage;
  final VoidCallback? onDismissWorkerActionMessage;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI Accounts',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Accounts used by Workers on your Workspaces.',
                      style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: onCreateAccount,
                icon: const Icon(Icons.add),
                label: const Text('Add AI Account'),
              ),
            ],
          ),
        ),
        if (workerActionMessage != null) ...[
          MaterialBanner(
            content: Text(workerActionMessage!),
            leading: const Icon(Icons.info_outline),
            actions: [
              TextButton(
                onPressed: onDismissWorkerActionMessage,
                child: const Text('Dismiss'),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (accounts.isEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No Accounts connected',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Connect an Account to make a Worker ready for execution.',
                    style: TextStyle(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Nothing to configure yet.',
                      style: TextStyle(color: Color(0xff777683)),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          const Text('Accounts',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 12),
          ...accounts.map(
            (account) => Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                leading: const CircleAvatar(
                  backgroundColor: Color(0xffeeecff),
                  child: Icon(Icons.account_circle_outlined,
                      color: Color(0xff6254d9), size: 20),
                ),
                title: Text(account.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    'Owner: ${account.owner}\nWorker: ${account.worker} · Workspace: ${account.host}\nStorage: ${account.storageLocation} · Sharing: ${account.sharing}\nLast used: ${account.lastUsed} · Usage: ${account.usage}'),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  tooltip: 'Account actions',
                  onSelected: (action) {
                    if (action == 'setup') {
                      onRequestAccountSetup?.call(account);
                    } else if (action == 'revoke') {
                      onRevokeAccount?.call(account);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'setup',
                      child: Text(account.status.toLowerCase() == 'ready'
                          ? 'Reconnect / re-authenticate'
                          : 'Connect Account'),
                    ),
                    const PopupMenuItem(
                      value: 'revoke',
                      child: Text('Revoke Account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
