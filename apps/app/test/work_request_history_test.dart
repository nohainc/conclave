import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in [
    ['direct', 1, 'Direct'],
    ['direct', 2, 'Work'],
    ['chat', 1, 'Chat'],
  ]) {
    test('${entry[0]} v${entry[1]} preserves its projected historical name',
        () {
      final request = AxWorkRequest.fromJson({
        'id': 'request',
        'workflowId': entry[0],
        'workflowVersion': entry[1],
        'workflowName': entry[2],
      });
      expect(request.workflowName, entry[2]);
      expect(request.workflowVersion, entry[1]);
    });
  }

  test('immutable snapshot name takes precedence over current presentation',
      () {
    final request = AxWorkRequest.fromJson({
      'workflowId': 'direct',
      'workflowVersion': 1,
      'workflowName': 'Work',
      'workflowSnapshot': {'id': 'direct', 'version': 1, 'name': 'Direct'},
    });
    expect(request.workflowName, 'Direct');
  });

  test('a different version snapshot cannot rename a historical request', () {
    final request = AxWorkRequest.fromJson({
      'workflowId': 'direct',
      'workflowVersion': 1,
      'workflowName': 'Direct',
      'workflowSnapshot': {'id': 'direct', 'version': 2, 'name': 'Work'},
    });
    expect(request.workflowName, 'Direct');
  });

  test('older read models without a name retain version for catalog lookup',
      () {
    final request =
        AxWorkRequest.fromJson({'workflowId': 'direct', 'workflowVersion': 1});
    expect(request.workflowName, isNull);
    expect(request.workflowVersion, 1);
  });
}
