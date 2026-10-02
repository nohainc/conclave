import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/passkey_browser_stub.dart'
    if (dart.library.html) '../auth/passkey_browser_web.dart' as passkeys;
import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'ax_models.dart';
import 'ax_work_models.dart';

export 'ax_work_models.dart';

part 'ax_data/catalog_api.dart';
part 'ax_data/workstream_api.dart';
part 'ax_data/auth_api.dart';
part 'ax_data/workspace_api.dart';
part 'ax_data/project_api.dart';
part 'ax_data/read_model_api.dart';

class AxApiException implements Exception {
  const AxApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

abstract class _AxApiClientCore implements AxDataSource {
  _AxApiClientCore({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ??
            (const String.fromEnvironment('CONCLAVE_API_URL').isNotEmpty
                ? const String.fromEnvironment('CONCLAVE_API_URL')
                : platform.defaultAxApiBaseUrl()),
        client = client ?? platform.createPlatformHttpClient();

  final String baseUrl;
  final http.Client client;
  final passkeyBrowser = passkeys.createAxPasskeyBrowser();
  String? sessionToken;

  Map<String, String> _headers({String? contentType}) => {
        'accept': 'application/json',
        if (contentType != null) 'content-type': contentType,
        if (sessionToken != null && sessionToken!.isNotEmpty)
          'authorization': 'Bearer $sessionToken',
      };

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final response = await client.get(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Read model failed for ${uri.path} (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AxApiException('Read model response is malformed');
    }
    return Map<String, dynamic>.from(decoded);
  }
}

class AxApiClient extends _AxApiClientCore
    with
        _CatalogApi,
        _WorkstreamApi,
        _AuthApi,
        _WorkspaceApi,
        _ProjectApi,
        _ReadModelApi {
  AxApiClient({super.baseUrl, super.client});
}
