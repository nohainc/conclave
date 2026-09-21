import 'package:http/http.dart' as http;

http.Client createPlatformHttpClient() => http.Client();

String defaultStudioApiBaseUrl() => 'http://localhost:8787/api';
