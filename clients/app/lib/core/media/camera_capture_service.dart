import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class CameraCaptureGateway {
  bool get isSupported;
  Future<XFile?> capturePhoto();
  Future<void> openAppSettings();
}

final class CameraCaptureService implements CameraCaptureGateway {
  CameraCaptureService({TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform;

  static const MethodChannel _channel = MethodChannel('dd/camera_capture');
  final TargetPlatform _platform;

  @override
  bool get isSupported => !kIsWeb && _platform == TargetPlatform.android;

  @override
  Future<XFile?> capturePhoto() async {
    if (!isSupported) {
      throw UnsupportedError('当前平台暂不支持直接拍摄。');
    }
    final path = await _channel.invokeMethod<String>('capturePhoto');
    if (path == null || path.trim().isEmpty) return null;
    return XFile(path.trim(), mimeType: 'image/jpeg');
  }

  @override
  Future<void> openAppSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openAppSettings');
  }
}
