import 'package:conclave_workspace/worker_executor.dart';

AssignmentLogicalWorker assignmentWorker(
  String id, {
  String workerTypeId = 'test-worker',
  Set<String> permissions = const {'workspace:read', 'workspace:write'},
  int localConcurrencyLimit = 1,
}) =>
    AssignmentLogicalWorker(
      id: id,
      workerTypeId: workerTypeId,
      enabled: true,
      ready: true,
      permissions: permissions,
      localConcurrencyLimit: localConcurrencyLimit,
    );
