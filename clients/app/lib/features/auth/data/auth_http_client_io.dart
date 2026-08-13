import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../../core/network/resilient_http_client.dart';

http.Client createAuthHttpClient() {
  final io = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 6;
  return ResilientHttpClient(IOClient(io));
}
