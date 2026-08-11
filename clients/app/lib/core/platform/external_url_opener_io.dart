import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _androidChannel = MethodChannel('dd/external_url');

Future<bool> openExternalUrl(Uri uri) async {
  try {
    if (Platform.isAndroid) {
      return await _androidChannel.invokeMethod<bool>('open', <String, Object>{
            'url': uri.toString(),
          }) ??
          false;
    }
    if (Platform.isWindows) {
      final process = await Process.start(
        'rundll32.exe',
        <String>['url.dll,FileProtocolHandler', uri.toString()],
        mode: ProcessStartMode.detached,
      );
      return process.pid > 0;
    }
    if (Platform.isMacOS) {
      final process = await Process.start(
        'open',
        <String>[uri.toString()],
        mode: ProcessStartMode.detached,
      );
      return process.pid > 0;
    }
    if (Platform.isLinux) {
      final process = await Process.start(
        'xdg-open',
        <String>[uri.toString()],
        mode: ProcessStartMode.detached,
      );
      return process.pid > 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
