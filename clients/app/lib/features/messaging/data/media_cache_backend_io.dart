import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

const int _maxCacheBytes = 512 * 1024 * 1024;

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
  await _pruneMediaCache();
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

Future<void> _pruneMediaCache() async {
  final directory = await _cacheDirectory();
  final entries = <({File file, int size, DateTime modified})>[];
  var total = 0;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.bin')) continue;
    try {
      final stat = await entity.stat();
      total += stat.size;
      entries.add((file: entity, size: stat.size, modified: stat.modified));
    } catch (_) {}
  }
  if (total <= _maxCacheBytes) return;
  entries.sort((a, b) => a.modified.compareTo(b.modified));
  for (final entry in entries) {
    if (total <= _maxCacheBytes) break;
    try {
      await entry.file.delete();
      total -= entry.size;
    } catch (_) {}
  }
}
