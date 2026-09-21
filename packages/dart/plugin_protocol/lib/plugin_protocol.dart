import 'dart:convert';

const pluginProtocolVersion = '2.0';
const pluginMethods = {
  'initialize',
  'health',
  'configure_worker',
  'start_assignment',
  'cancel_assignment',
  'shutdown',
};

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
  if (id is! String || method is! String || !pluginMethods.contains(method)) {
    throw const JsonRpcException('unsupported plugin method');
  }
  final params = input['params'];
  return JsonRpcRequest(
    id: id,
    method: method,
    params: params is Map ? Map<String, Object?>.from(params) : const {},
  );
}
