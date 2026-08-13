import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';

import 'chat_image_processor.dart';

abstract interface class ClipboardGateway {
  Future<Uint8List?> readImageBytes();

  Future<List<String>> readFiles();

  Future<String?> readText();
}

final class PasteboardClipboardGateway implements ClipboardGateway {
  const PasteboardClipboardGateway();

  @override
  Future<Uint8List?> readImageBytes() => Pasteboard.image;

  @override
  Future<List<String>> readFiles() => Pasteboard.files();

  @override
  Future<String?> readText() => Pasteboard.text;
}

enum ClipboardImageErrorCode {
  readFailed,
  malformedImage,
  imageTooLarge,
  fileUnavailable,
}

final class ClipboardImageError implements Exception {
  const ClipboardImageError(this.code, this.message, {this.cause});

  final ClipboardImageErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ClipboardImageError($code, $message)';
}

final class ClipboardImagePayload {
  const ClipboardImagePayload._({
    required this.bytes,
    required this.path,
    required this.mimeType,
    required this.suggestedName,
    required this.sizeBytes,
  }) : assert((bytes == null) != (path == null));

  factory ClipboardImagePayload.bytes({
    required Uint8List bytes,
    required String mimeType,
    required String suggestedName,
  }) {
    return ClipboardImagePayload._(
      bytes: bytes,
      path: null,
      mimeType: mimeType,
      suggestedName: suggestedName,
      sizeBytes: bytes.length,
    );
  }

  factory ClipboardImagePayload.path({
    required String path,
    required String mimeType,
    required String suggestedName,
    required int sizeBytes,
  }) {
    return ClipboardImagePayload._(
      bytes: null,
      path: path,
      mimeType: mimeType,
      suggestedName: suggestedName,
      sizeBytes: sizeBytes,
    );
  }

  final Uint8List? bytes;
  final String? path;
  final String mimeType;
  final String suggestedName;
  final int sizeBytes;

  XFile toXFile() {
    final filePath = path;
    if (filePath != null) {
      return XFile(filePath, mimeType: mimeType, name: suggestedName);
    }
    return XFile.fromData(bytes!, mimeType: mimeType, name: suggestedName);
  }
}

enum ClipboardImageReadKind { image, noImage, error }

final class ClipboardImageReadResult {
  const ClipboardImageReadResult._({
    required this.kind,
    this.image,
    this.error,
  });

  const ClipboardImageReadResult.image(ClipboardImagePayload image)
    : this._(kind: ClipboardImageReadKind.image, image: image);

  const ClipboardImageReadResult.noImage()
    : this._(kind: ClipboardImageReadKind.noImage);

  const ClipboardImageReadResult.error(ClipboardImageError error)
    : this._(kind: ClipboardImageReadKind.error, error: error);

  final ClipboardImageReadKind kind;
  final ClipboardImagePayload? image;
  final ClipboardImageError? error;
}

final class WindowsClipboardImageAdapter {
  WindowsClipboardImageAdapter({
    ClipboardGateway? gateway,
    DateTime Function()? now,
  }) : _gateway = gateway ?? const PasteboardClipboardGateway(),
       _now = now ?? DateTime.now;

  final ClipboardGateway _gateway;
  final DateTime Function() _now;

  Future<ClipboardImageReadResult> readImage() async {
    ClipboardImageError? deferredError;

    try {
      final bytes = await _gateway.readImageBytes();
      if (bytes != null) {
        final result = _payloadFromBytes(bytes);
        if (result.kind == ClipboardImageReadKind.image) return result;
        deferredError = result.error;
      }
    } catch (error) {
      deferredError = ClipboardImageError(
        ClipboardImageErrorCode.readFailed,
        '读取 Windows 剪贴板图片失败。',
        cause: error,
      );
    }

    try {
      final paths = await _gateway.readFiles();
      for (final rawPath in paths) {
        final mimeType = _imageMimeFromPath(rawPath);
        if (mimeType == null) continue;
        try {
          final file = File(rawPath);
          if (!await file.exists()) {
            deferredError ??= const ClipboardImageError(
              ClipboardImageErrorCode.fileUnavailable,
              '剪贴板中的图片文件已不存在。',
            );
            continue;
          }
          final sizeBytes = await file.length();
          if (sizeBytes <= 0) {
            deferredError ??= const ClipboardImageError(
              ClipboardImageErrorCode.malformedImage,
              '剪贴板中的图片文件为空。',
            );
            continue;
          }
          if (sizeBytes > maxChatImageSourceBytes) {
            return const ClipboardImageReadResult.error(
              ClipboardImageError(
                ClipboardImageErrorCode.imageTooLarge,
                '剪贴板图片超过 96 MiB，无法发送。',
              ),
            );
          }
          return ClipboardImageReadResult.image(
            ClipboardImagePayload.path(
              path: rawPath,
              mimeType: mimeType,
              suggestedName: _safeFileName(_baseName(rawPath), mimeType),
              sizeBytes: sizeBytes,
            ),
          );
        } catch (error) {
          deferredError ??= ClipboardImageError(
            ClipboardImageErrorCode.fileUnavailable,
            '读取剪贴板中的图片文件失败。',
            cause: error,
          );
        }
      }
    } catch (error) {
      deferredError ??= ClipboardImageError(
        ClipboardImageErrorCode.readFailed,
        '读取 Windows 剪贴板文件失败。',
        cause: error,
      );
    }

    if (deferredError != null) {
      return ClipboardImageReadResult.error(deferredError);
    }
    return const ClipboardImageReadResult.noImage();
  }

  Future<bool> hasTextRepresentation() async {
    try {
      return await _gateway.readText() != null;
    } catch (_) {
      return false;
    }
  }

  ClipboardImageReadResult _payloadFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const ClipboardImageReadResult.error(
        ClipboardImageError(
          ClipboardImageErrorCode.malformedImage,
          '剪贴板图片内容为空。',
        ),
      );
    }
    if (bytes.length > maxChatImageSourceBytes) {
      return const ClipboardImageReadResult.error(
        ClipboardImageError(
          ClipboardImageErrorCode.imageTooLarge,
          '剪贴板图片超过 96 MiB，无法发送。',
        ),
      );
    }

    try {
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0) {
        return const ClipboardImageReadResult.error(
          ClipboardImageError(
            ClipboardImageErrorCode.malformedImage,
            '无法解析剪贴板图片。',
          ),
        );
      }
      if (info.width * info.height > maxChatImageSourcePixels) {
        return const ClipboardImageReadResult.error(
          ClipboardImageError(
            ClipboardImageErrorCode.imageTooLarge,
            '剪贴板图片像素尺寸过大，无法发送。',
          ),
        );
      }
    } catch (error) {
      return ClipboardImageReadResult.error(
        ClipboardImageError(
          ClipboardImageErrorCode.malformedImage,
          '无法解析剪贴板图片。',
          cause: error,
        ),
      );
    }

    final mimeType = _imageMimeFromBytes(bytes);
    if (mimeType == null) {
      return const ClipboardImageReadResult.error(
        ClipboardImageError(
          ClipboardImageErrorCode.malformedImage,
          '剪贴板图片格式无法识别。',
        ),
      );
    }
    final extension = _extensionForMime(mimeType);
    final name = 'DD-clipboard-${_now().microsecondsSinceEpoch}.$extension';
    return ClipboardImageReadResult.image(
      ClipboardImagePayload.bytes(
        bytes: bytes,
        mimeType: mimeType,
        suggestedName: name,
      ),
    );
  }
}

enum ClipboardPasteDecisionKind {
  passThrough,
  consumeImage,
  consumeDuplicateImage,
  showImageError,
}

final class ClipboardPasteDecision {
  const ClipboardPasteDecision._({required this.kind, this.image, this.error});

  const ClipboardPasteDecision.passThrough()
    : this._(kind: ClipboardPasteDecisionKind.passThrough);

  const ClipboardPasteDecision.consumeImage(ClipboardImagePayload image)
    : this._(kind: ClipboardPasteDecisionKind.consumeImage, image: image);

  const ClipboardPasteDecision.consumeDuplicateImage()
    : this._(kind: ClipboardPasteDecisionKind.consumeDuplicateImage);

  const ClipboardPasteDecision.showImageError(ClipboardImageError error)
    : this._(kind: ClipboardPasteDecisionKind.showImageError, error: error);

  final ClipboardPasteDecisionKind kind;
  final ClipboardImagePayload? image;
  final ClipboardImageError? error;

  bool get shouldConsumeShortcut =>
      kind != ClipboardPasteDecisionKind.passThrough;
}

final class WindowsClipboardPasteDecider {
  factory WindowsClipboardPasteDecider({
    required WindowsClipboardImageAdapter adapter,
    TargetPlatform? platform,
    bool? isWeb,
  }) {
    return WindowsClipboardPasteDecider._(
      adapter,
      platform: platform,
      isWeb: isWeb,
    );
  }

  WindowsClipboardPasteDecider._(
    this._adapter, {
    TargetPlatform? platform,
    bool? isWeb,
  }) : _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb;

  final WindowsClipboardImageAdapter _adapter;
  final TargetPlatform _platform;
  final bool _isWeb;

  Future<ClipboardPasteDecision> decide({bool isKeyRepeat = false}) async {
    if (_isWeb || _platform != TargetPlatform.windows) {
      return const ClipboardPasteDecision.passThrough();
    }

    final result = await _adapter.readImage();
    switch (result.kind) {
      case ClipboardImageReadKind.image:
        if (isKeyRepeat) {
          return const ClipboardPasteDecision.consumeDuplicateImage();
        }
        return ClipboardPasteDecision.consumeImage(result.image!);
      case ClipboardImageReadKind.noImage:
        return const ClipboardPasteDecision.passThrough();
      case ClipboardImageReadKind.error:
        if (await _adapter.hasTextRepresentation()) {
          return const ClipboardPasteDecision.passThrough();
        }
        return ClipboardPasteDecision.showImageError(result.error!);
    }
  }
}

String? _imageMimeFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  return null;
}

String? _imageMimeFromBytes(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return 'image/bmp';
  }
  return null;
}

String _extensionForMime(String mimeType) {
  return switch (mimeType) {
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'image/bmp' => 'bmp',
    _ => 'png',
  };
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? '' : parts.last;
}

String _safeFileName(String raw, String mimeType) {
  var value = raw.trim().replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  value = value.replaceAll(RegExp(r'[ .]+$'), '');
  if (value.isEmpty || RegExp(r'^\.+$').hasMatch(value)) {
    value = 'DD-clipboard.${_extensionForMime(mimeType)}';
  }
  if (value.length > 120) value = value.substring(0, 120);
  return value;
}
