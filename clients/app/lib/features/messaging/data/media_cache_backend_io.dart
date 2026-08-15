import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../../core/media/media_cache_lease_registry.dart';
import '../../../core/media/media_cache_manager_backend_io.dart'
    show pruneManagedMediaCache;

Future<Directory> _cacheDirectory() async {
  final base = await getApplicationSupportDirectory();
  final directory = Directory(
    '${base.path}${Platform.pathSeparator}media_cache_v1',
  );
  if (!await directory.exists()) await directory.create(recursive: true);
  return directory;
}

Future<File> _cacheFile(String cacheKey) async {
  final directory = await _cacheDirectory();
  return File('${directory.path}${Platform.pathSeparator}$cacheKey.bin');
}

Future<Uint8List?> readMediaCacheFile(String cacheKey) async {
  final file = await _cacheFile(cacheKey);
  if (!await file.exists()) return null;
  try {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      await file.delete();
      return null;
    }
    try {
      final now = DateTime.now();
      await file.setLastModified(now);
    } catch (_) {}
    return bytes;
  } on FileSystemException {
    return null;
  }
}

Future<void> writeMediaCacheFile(String cacheKey, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  final file = await _cacheFile(cacheKey);
  final temp = File('${file.path}.tmp');
  await MediaCacheLeaseRegistry.shared.withLease(file.path, () async {
    await MediaCacheLeaseRegistry.shared.withLease(temp.path, () async {
      await temp.writeAsBytes(bytes, flush: true);
      if (await file.exists()) {
        try {
          await file.delete();
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          if (await file.exists()) await file.delete();
        }
      }
      await temp.rename(file.path);
    });
  });
  await pruneManagedMediaCache();
}

Future<String?> mediaCacheFilePathIfPresent(String cacheKey) async {
  final file = await _cacheFile(cacheKey);
  if (!await file.exists()) return null;
  try {
    if (await file.length() <= 0) return null;
    await file.setLastModified(DateTime.now());
    return file.path;
  } on FileSystemException {
    return null;
  }
}

Future<void> deleteMediaCacheFile(String cacheKey) async {
  final file = await _cacheFile(cacheKey);
  if (!await file.exists()) return;
  try {
    await file.delete();
  } on FileSystemException {
    // Best-effort cache eviction; a transient Windows file lock is harmless.
  }
}

