import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _ddFilePickerChannel = MethodChannel('dd/file_picker');

enum DdFilePickerSource { files, photos }

enum DdPickedMediaKind { file, photo, video, livePhoto }

final class DdPickedMedia {
  const DdPickedMedia({
    required this.kind,
    required this.primary,
    this.motion,
    this.assetIdentifier,
    this.primarySizeBytes,
    this.motionSizeBytes,
  });

  final DdPickedMediaKind kind;
  final XFile primary;
  final XFile? motion;
  final String? assetIdentifier;
  final int? primarySizeBytes;
  final int? motionSizeBytes;

  bool get isLivePhoto => kind == DdPickedMediaKind.livePhoto;
  int? get totalSizeBytes {
    final primarySize = primarySizeBytes;
    if (primarySize == null) return null;
    return primarySize + (motionSizeBytes ?? 0);
  }
}

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

Future<List<DdPickedMedia>> ddOpenMediaFiles({
  List<XTypeGroup>? acceptedTypeGroups,
  DdFilePickerSource source = DdFilePickerSource.files,
  int? maxFiles,
  int? maxBytes,
}) async {
  if (!_usesNativeDdPicker) {
    final files = await openFiles(
      acceptedTypeGroups: acceptedTypeGroups ?? const <XTypeGroup>[],
    );
    return files
        .map(
          (file) => DdPickedMedia(
            kind: _kindForMimeType(file.mimeType, source: source),
            primary: file,
          ),
        )
        .toList(growable: false);
  }
  return _nativeOpenPickedMedia(
    acceptedTypeGroups: acceptedTypeGroups,
    source: source,
    allowMultiple: true,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
    preserveLivePhoto: true,
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
  final media = await _nativeOpenPickedMedia(
    acceptedTypeGroups: acceptedTypeGroups,
    source: source,
    allowMultiple: allowMultiple,
    maxFiles: maxFiles,
    maxBytes: maxBytes,
    preserveLivePhoto: false,
  );
  return media.map((item) => item.primary).toList(growable: false);
}

Future<List<DdPickedMedia>> _nativeOpenPickedMedia({
  required List<XTypeGroup>? acceptedTypeGroups,
  required DdFilePickerSource source,
  required bool allowMultiple,
  required int? maxFiles,
  required int? maxBytes,
  required bool preserveLivePhoto,
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
        'preserveLivePhoto': preserveLivePhoto,
      });
  if (raw == null || raw.isEmpty) return const <DdPickedMedia>[];

  final media = <DdPickedMedia>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final kind = _parseKind(item['kind'], source: source);
    if (kind == DdPickedMediaKind.livePhoto) {
      final still = _parsePickedFile(item['still']);
      final motion = _parsePickedFile(item['motion']);
      if (still == null || motion == null) {
        throw const FormatException(
          'Live Photo picker result is missing a component',
        );
      }
      media.add(
        DdPickedMedia(
          kind: kind,
          primary: still.file,
          motion: motion.file,
          assetIdentifier: _optionalString(item['assetIdentifier']),
          primarySizeBytes: still.sizeBytes,
          motionSizeBytes: motion.sizeBytes,
        ),
      );
      continue;
    }
    final file = _parsePickedFile(item);
    if (file == null) continue;
    media.add(
      DdPickedMedia(
        kind: kind,
        primary: file.file,
        primarySizeBytes: file.sizeBytes,
        assetIdentifier: _optionalString(item['assetIdentifier']),
      ),
    );
  }
  return media;
}

_DdPickedFile? _parsePickedFile(Object? raw) {
  if (raw is! Map) return null;
  final path = raw['path'];
  if (path is! String || path.trim().isEmpty) return null;
  final size = raw['size'];
  return _DdPickedFile(
    file: XFile(
      path,
      name: _optionalString(raw['name']),
      mimeType: _optionalString(raw['mimeType']),
    ),
    sizeBytes: size is int ? size : (size is num ? size.toInt() : null),
  );
}

DdPickedMediaKind _parseKind(
  Object? raw, {
  required DdFilePickerSource source,
}) {
  switch (raw?.toString()) {
    case 'photo':
      return DdPickedMediaKind.photo;
    case 'video':
      return DdPickedMediaKind.video;
    case 'livePhoto':
      return DdPickedMediaKind.livePhoto;
    case 'file':
      return DdPickedMediaKind.file;
    default:
      return source == DdFilePickerSource.photos
          ? DdPickedMediaKind.photo
          : DdPickedMediaKind.file;
  }
}

DdPickedMediaKind _kindForMimeType(
  String? mimeType, {
  required DdFilePickerSource source,
}) {
  final normalized = mimeType?.toLowerCase() ?? '';
  if (normalized.startsWith('video/')) return DdPickedMediaKind.video;
  if (normalized.startsWith('image/')) return DdPickedMediaKind.photo;
  return source == DdFilePickerSource.photos
      ? DdPickedMediaKind.photo
      : DdPickedMediaKind.file;
}

String? _optionalString(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return raw;
}

final class _DdPickedFile {
  const _DdPickedFile({required this.file, required this.sizeBytes});

  final XFile file;
  final int? sizeBytes;
}
