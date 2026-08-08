import 'package:http/http.dart' as http;

import 'auth_http_client_io.dart'
    if (dart.library.js_interop) 'auth_http_client_web.dart'
    as platform;

http.Client createAuthHttpClient() => platform.createAuthHttpClient();
