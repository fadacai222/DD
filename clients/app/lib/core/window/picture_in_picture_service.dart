import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final class PictureInPictureService {
  PictureInPictureService._();

  static final PictureInPictureService shared = PictureInPictureService._();
  static const MethodChannel _channel = MethodChannel('dd/picture_in_picture');

  Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> enter({int width = 16, int height = 9}) async {
    if (!await isSupported()) return false;
    try {
      return await _channel.invokeMethod<bool>('enter', {
            'width': width,
            'height': height,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
