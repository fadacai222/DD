import 'package:flutter/foundation.dart';

Future<bool> openExternalUrl(Uri uri) async {
  debugPrint('External URL opening is unavailable on this platform: $uri');
  return false;
}
