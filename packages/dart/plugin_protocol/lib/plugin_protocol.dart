import 'dart:convert';

const workerProtocolVersion = '4.0';
const workerMethods = {
  'initialize',
  'health',
  'describe',
  'execute',
  'cancel',
  'shutdown',
};

const workerNotifications = {
  'progress',
  'usage',
  'artifact',
  'result',
  'error',
  'log',
};

const pluginProtocolVersion = workerProtocolVersion;

class JsonRpcException implements Exception {
  const JsonRpcException(this.message, {this.code = -32600});
  final String message;
  final int code;

  @override
  String toString() => 'JsonRpcException($code): $message';
}

class JsonRpcRequest {
  const JsonRpcRequest(
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

class JsonRpcNotification {
  const JsonRpcNotification({required this.method, this.params = const {}});
  final String method;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      };

  String encode() => jsonEncode(toJson());
}

class JsonRpcResponse {
  const JsonRpcResponse({required this.id, this.result, this.error});
  final String id;
  final Object? result;
  final JsonRpcException? error;

  Map<String, Object?> toJson() => {
        'jsonrpc': '2.0',
        'id': id,
        if (error == null) 'result': result,
        if (error != null)
          'error': {'code': error!.code, 'message': error!.message},
      };
}

JsonRpcRequest parseRequest(Object? input) {
  if (input is String) input = jsonDecode(input);
  if (input is! Map || input['jsonrpc'] != '2.0') {
    throw const JsonRpcException('invalid JSON-RPC request');
  }
  final id = input['id'];
  final method = input['method'];
  if ((id is! String && id is! num) ||
      method is! String ||
      !workerMethods.contains(method)) {
    throw const JsonRpcException('unsupported worker method');
  }
  final params = input['params'];
  return JsonRpcRequest(
    id: id.toString(),
    method: method,
    params: params is Map ? Map<String, Object?>.from(params) : const {},
  );
}

JsonRpcNotification parseNotification(Object? input) {
  if (input is String) input = jsonDecode(input);
  if (input is! Map || input['jsonrpc'] != '2.0') {
    throw const JsonRpcException('invalid JSON-RPC notification');
  }
  final method = input['method'];
  if (method is! String || !workerNotifications.contains(method)) {
    throw const JsonRpcException('unsupported worker notification');
  }
  final params = input['params'];
  _validateNotificationParams(method, params);
  return JsonRpcNotification(
    method: method,
    params: params is Map ? Map<String, Object?>.from(params) : const {},
  );
}

void _validateNotificationParams(String method, Object? params) {
  if (params is! Map) {
    throw const JsonRpcException(
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
      throw const JsonRpcException('worker progress percentage is invalid');
    }
  }
  if (method == 'result') {
    _required(map, 'status');
    _required(map, 'completedAt');
    if (!map.containsKey('output')) {
      throw const JsonRpcException('worker result output is required');
    }
  }
  if (method == 'error') {
    _required(map, 'code');
    _required(map, 'message');
    _required(map, 'timestamp');
  }
}

void _required(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw JsonRpcException('worker notification $key is required');
  }
}
