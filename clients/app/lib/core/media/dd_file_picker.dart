import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _ddFilePickerChannel = MethodChannel('dd/file_picker');

Future<XFile?> ddOpenFile({
  List<XTypeGroup>? acceptedTypeGroups,
  int? maxBytes,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return openFile(
      acceptedTypeGroups: acceptedTypeGroups ?? const <XTypeGroup>[],
    );
  }
  final files = await _androidOpenFiles(
    acceptedTypeGroups: acceptedTypeGroups,
    allowMultiple: false,
    maxFiles: 1,
    maxBytes: maxBytes,
  );
  return files.isEmpty ? null : files.first;
}

Future<List<XFile>> ddOpenFiles({
  List<XTypeGroup>? acceptedTypeGroups,
  int? maxFiles,
  int? maxBytes,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return openFiles(
      acceptedTypeGroups: acceptedTypeGroups ?? const <XTypeGroup>[],
    );
  }
  return _androidOpenFiles(
    acceptedTypeGroups: acceptedTypeGroups,
    allowMultiple: true,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
  );
}

Future<List<XFile>> _androidOpenFiles({
  required List<XTypeGroup>? acceptedTypeGroups,
  required bool allowMultiple,
  required int? maxFiles,
  required int? maxBytes,
}) async {
  final mimeTypes = <String>{};
  for (final group in acceptedTypeGroups ?? const <XTypeGroup>[]) {
    mimeTypes.addAll(group.mimeTypes ?? const <String>[]);
  }
  final raw = await _ddFilePickerChannel.invokeListMethod<dynamic>(
    'openFiles',
    <String, Object?>{
      'allowMultiple': allowMultiple,
      'mimeTypes': mimeTypes.toList(growable: false),
      'maxFiles': ?maxFiles,
      'maxBytes': ?maxBytes,
    },
  );
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
