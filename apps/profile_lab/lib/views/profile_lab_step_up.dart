import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';

void showProfileLabOperationFailure(
  BuildContext context,
  ProfileLabController controller,
  String operation,
  Object error,
) {
  final message = error.toString();
  if (!message.contains('Fresh strong authentication required')) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$operation failed: $error')),
    );
    return;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: const Text(
        'Complete a passkey verification in Conclave in your browser, then bind it to this Profile Lab session.',
      ),
      action: SnackBarAction(
        label: 'Bind passkey',
        onPressed: () async {
          try {
            await controller.completeStepUpFromBrowser();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Passkey step-up is ready. Retry the operation.'),
              ),
            );
          } catch (stepUpError) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Passkey step-up failed: $stepUpError')),
            );
          }
        },
      ),
    ),
  );
}
