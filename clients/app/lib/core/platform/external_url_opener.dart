import 'external_url_opener_stub.dart'
    if (dart.library.io) 'external_url_opener_io.dart'
    if (dart.library.html) 'external_url_opener_web.dart' as platform;

Future<bool> openExternalHttpUrl(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty) {
    return Future<bool>.value(false);
  }
  return platform.openExternalUrl(uri);
}
