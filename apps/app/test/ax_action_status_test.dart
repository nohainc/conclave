import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_action_status.dart';

void main() {
  test('invitations map onto the shared lifecycle', () {
    expect(axInvitationStatus('pending'), AxActionStatus.accepted);
    expect(axInvitationStatus('pending').label(AxActionKind.invitation),
        'Sent');
    expect(axInvitationStatus('accepted'), AxActionStatus.responded);
    expect(axInvitationStatus('declined'), AxActionStatus.responded);
    expect(axInvitationStatus('expired').finished, isTrue);
    expect(axInvitationStatus('revoked').label(AxActionKind.invitation),
        'Cancelled');
  });

  test('a queued work request reads as received', () {
    final status = axWorkRequestStatus('queued');
    expect(status.label(AxActionKind.workRequest), 'Received');
    expect(status.finished, isFalse);
    expect(axWorkRequestStatus('failed').problem, isTrue);
    expect(axWorkRequestStatus('completed'), AxActionStatus.processed);
  });
}
