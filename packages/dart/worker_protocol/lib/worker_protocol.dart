import 'dart:convert';

const workerProtocolVersion = '4.0';
const workerProtocolMethods = {
  'initialize',
  'health',
  'describe',
  'execute',
  'cancel',
  'shutdown',
};

const workerProtocolNotifications = {
  'progress',
  'status',
  'output_delta',
  'tool.started',
  'tool.completed',
  'usage',
  'artifact',
  'result',
  'error',
  'log',
};

class WorkerRpcException implements Exception {
  const WorkerRpcException(this.message, {this.code = -32600});
  final String message;
  final int code;

  @override
  String toString() => 'WorkerRpcException($code): $message';
}

class WorkerRpcRequest {
  const WorkerRpcRequest(
      {required this.id, required this.method, this.params = const {}});
  final String id;
  final String method;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      };

  String encode() => jsonEncode(toJson());
}

class WorkerRpcNotification {
  const WorkerRpcNotification({required this.method, this.params = const {}});
  final String method;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      };

  String encode() => jsonEncode(toJson());
}

class WorkerRpcResponse {
  const WorkerRpcResponse({required this.id, this.result, this.error});
  final String id;
  final Object? result;
  final WorkerRpcException? error;

  Map<String, Object?> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        if (error == null) 'result': result,
        if (error != null)
          'error': {'code': error!.code, 'message': error!.message},
      };
}

WorkerRpcRequest parseWorkerRequest(Object? input) {
  if (input is String) input = jsonDecode(input);
  if (input is! Map || input['jsonrpc'] != '2.0') {
    throw const WorkerRpcException('invalid JSON-RPC request');
  }
  final id = input['id'];
  final method = input['method'];
  if ((id is! String && id is! num) ||
      method is! String ||
      !workerProtocolMethods.contains(method)) {
    throw const WorkerRpcException('unsupported worker method');
  }
  final params = input['params'];
  return WorkerRpcRequest(
    id: id.toString(),
    method: method,
    params: params is Map ? Map<String, Object?>.from(params) : const {},
  );
}

WorkerRpcNotification parseWorkerNotification(Object? input) {
  if (input is String) input = jsonDecode(input);
  if (input is! Map || input['jsonrpc'] != '2.0') {
    throw const WorkerRpcException('invalid JSON-RPC notification');
  }
  final method = input['method'];
  if (method is! String || !workerProtocolNotifications.contains(method)) {
    throw const WorkerRpcException('unsupported worker notification');
  }
  final params = input['params'];
  _validateNotificationParams(method, params);
  return WorkerRpcNotification(
    method: method,
    params: params is Map ? Map<String, Object?>.from(params) : const {},
  );
}

void _validateNotificationParams(String method, Object? params) {
  if (params is! Map) {
    throw const WorkerRpcException(
        'worker notification params must be an object');
  }
  final map = Map<String, Object?>.from(params);
  if (method == 'log') {
    _required(map, 'level');
    _required(map, 'message');
    _required(map, 'timestamp');
    return;
  }
  _required(map, 'assignmentId');
  if (method == 'progress') {
    final percentage = map['percentage'];
    if (percentage is! num || percentage < 0 || percentage > 100) {
      throw const WorkerRpcException('worker progress percentage is invalid');
    }
  }
  if (method == 'status') {
    _required(map, 'status');
    _required(map, 'timestamp');
    _maxLength(map['message'], 'status message', 8192);
  }
  if (method == 'output_delta') {
    _required(map, 'delta');
    _required(map, 'timestamp');
    _maxLength(map['delta'], 'output delta', 8192);
  }
  if (method == 'tool.started' || method == 'tool.completed') {
    _required(map, 'toolCallId');
    _required(map, 'tool');
    _required(map, 'timestamp');
    if (method == 'tool.completed' && map['success'] is! bool) {
      throw const WorkerRpcException('tool completion success is required');
    }
  }
  if (method == 'result') {
    _required(map, 'status');
    _required(map, 'completedAt');
    if (!map.containsKey('output')) {
      throw const WorkerRpcException('worker result output is required');
    }
  }
  if (method == 'error') {
    _required(map, 'code');
    _required(map, 'message');
    _required(map, 'timestamp');
  }
}

void _maxLength(Object? value, String name, int maximum) {
  if (value is String && value.length > maximum) {
    throw WorkerRpcException('$name exceeds $maximum characters');
  }
}

void _required(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw WorkerRpcException('worker notification $key is required');
  }
}
