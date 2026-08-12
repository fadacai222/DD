import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _ddFilePickerChannel = MethodChannel('dd/file_picker');

enum DdFilePickerSource { files, photos }

bool isDdPhotoLibraryPermissionError(PlatformException error) =>
    error.code == 'PHOTO_LIBRARY_PERMISSION_DENIED' ||
    error.code == 'PHOTO_LIBRARY_ADD_PERMISSION_DENIED';

bool get _usesNativeDdPicker =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<XFile?> ddOpenFile({
  List<XTypeGroup>? acceptedTypeGroups,
  DdFilePickerSource source = DdFilePickerSource.files,
  int? maxBytes,
}) async {
  if (!_usesNativeDdPicker) {
    return openFile(
      acceptedTypeGroups: acceptedTypeGroups ?? const <XTypeGroup>[],
    );
  }
  final files = await _nativeOpenFiles(
    acceptedTypeGroups: acceptedTypeGroups,
    source: source,
    allowMultiple: false,
    maxFiles: 1,
    maxBytes: maxBytes,
  );
  return files.isEmpty ? null : files.first;
}

Future<List<XFile>> ddOpenFiles({
  List<XTypeGroup>? acceptedTypeGroups,
  DdFilePickerSource source = DdFilePickerSource.files,
  int? maxFiles,
  int? maxBytes,
}) async {
  if (!_usesNativeDdPicker) {
    return openFiles(
      acceptedTypeGroups: acceptedTypeGroups ?? const <XTypeGroup>[],
    );
  }
  return _nativeOpenFiles(
    acceptedTypeGroups: acceptedTypeGroups,
    source: source,
    allowMultiple: true,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
  );
}

Future<void> ddOpenFilePickerAppSettings() async {
  if (!_usesNativeDdPicker) return;
  await _ddFilePickerChannel.invokeMethod<void>('openAppSettings');
}

Future<List<XFile>> _nativeOpenFiles({
  required List<XTypeGroup>? acceptedTypeGroups,
  required DdFilePickerSource source,
  required bool allowMultiple,
  required int? maxFiles,
  required int? maxBytes,
}) async {
  final mimeTypes = <String>{};
  for (final group in acceptedTypeGroups ?? const <XTypeGroup>[]) {
    mimeTypes.addAll(group.mimeTypes ?? const <String>[]);
  }
  final raw = await _ddFilePickerChannel
      .invokeListMethod<dynamic>('openFiles', <String, Object?>{
        'allowMultiple': allowMultiple,
        'source': source.name,
        'mimeTypes': mimeTypes.toList(growable: false),
        'maxFiles': ?maxFiles,
        'maxBytes': ?maxBytes,
      });
  if (raw == null || raw.isEmpty) return const <XFile>[];

  final files = <XFile>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final path = item['path'];
    if (path is! String || path.trim().isEmpty) continue;
    final name = item['name'];
    final mimeType = item['mimeType'];
    files.add(
      XFile(
        path,
        name: name is String && name.trim().isNotEmpty ? name : null,
        mimeType: mimeType is String && mimeType.trim().isNotEmpty
            ? mimeType
            : null,
      ),
    );
  }
  return files;
}
