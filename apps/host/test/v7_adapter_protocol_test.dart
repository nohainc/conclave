import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_host/v7_adapter_protocol.dart';

void main() {
  test('serializes version 2.3 probe requests with strict safe config', () {
    final frame = serializeV7AdapterFrame({
      'type': 'probe.request',
      'protocolVersion': v7AdapterProtocolVersion,
      'requestId': 'probe-1',
      'mode': 'passive',
      'config': {
        'endpointUrl': 'https://api.example.test/v1',
      },
    });
    expect(jsonDecode(frame), {
      'type': 'probe.request',
      'protocolVersion': '2.3',
      'requestId': 'probe-1',
      'mode': 'passive',
      'config': {
        'endpointUrl': 'https://api.example.test/v1',
      },
    });
    expect(
      () => serializeV7AdapterFrame({
        'type': 'probe.request',
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': 'probe-2',
        'mode': 'passive',
        'config': {
          'providerToken': 'must-not-cross-protocol',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => serializeV7AdapterFrame({
        'type': 'probe.request',
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': 'probe-3',
        'mode': 'passive',
        'config': {
          'endpointUrl': 'https://api.example.test/?token=secret',
        },
      }),
      throwsFormatException,
    );
  });

  test('parses structured bounded checks and rejects secrets or missing IDs',
      () {
    final response = {
      'type': 'probe.result',
      'protocolVersion': '2.3',
      'requestId': 'probe-1',
      'ready': true,
      'toolVersion': '1.2.3',
      'mode': 'passive',
      'checks': <Object>[
        {'id': 'tool_version', 'status': 'passed'},
      ],
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
