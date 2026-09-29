import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/v7_adapter_protocol.dart';

void main() {
  test('serializes version 2.1 probe requests with strict safe config', () {
    final frame = serializeV7AdapterFrame({
      'type': 'probe.request',
      'protocolVersion': v7AdapterProtocolVersion,
      'requestId': 'probe-1',
      'config': {'endpointUrl': 'https://api.example.test/v1'},
    });
    expect(jsonDecode(frame), {
      'type': 'probe.request',
      'protocolVersion': '2.1',
      'requestId': 'probe-1',
      'config': {'endpointUrl': 'https://api.example.test/v1'},
    });
    expect(
      () => serializeV7AdapterFrame({
        'type': 'probe.request',
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': 'probe-2',
        'config': {'providerToken': 'must-not-cross-protocol'},
      }),
      throwsFormatException,
    );
    expect(
      () => serializeV7AdapterFrame({
        'type': 'probe.request',
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': 'probe-3',
        'config': {'endpointUrl': 'https://api.example.test/?token=secret'},
      }),
      throwsFormatException,
    );
  });

  test('parses bounded probe results and rejects secrets or missing IDs', () {
    final response = {
      'type': 'probe.result',
      'protocolVersion': '2.1',
      'requestId': 'probe-1',
      'ready': true,
      'toolVersion': '1.2.3',
      'checkKind': 'readiness',
      'issues': <Object>[],
    };
    expect(parseV7AdapterFrame(jsonEncode(response)), response);
    expect(
      () => parseV7AdapterFrame(
        jsonEncode({...response, 'accountSecret': 'must-not-cross-protocol'}),
      ),
      throwsFormatException,
    );
    expect(
      () => parseV7AdapterFrame(
        jsonEncode({...response}..remove('requestId')),
      ),
      throwsFormatException,
    );
  });
}
