import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'media_cache_budget.dart';
import 'media_cache_lease_registry.dart';

Future<Map<String, int>> readManagedMediaCacheSnapshot() async {
  final totals = <String, int>{
    'image': 0,
    'video': 0,
    'file': 0,
    'voice': 0,
    'stickerGif': 0,
    'temporary': 0,
  };
  for (final entry in await _managedEntries()) {
    totals[entry.kind] = (totals[entry.kind] ?? 0) + entry.size;
  }
  return totals;
}

Future<void> clearManagedMediaCacheKind(String kind) async {
  for (final entry in await _managedEntries()) {
    if (entry.kind != kind) continue;
    await _safeDelete(entry.file);
  }
}

Future<void> clearAllManagedMediaCache() async {
  for (final entry in await _managedEntries()) {
    await _safeDelete(entry.file);
  }
}

Future<void> pruneManagedMediaCache() async {
  final entries = await _managedEntries();
  var total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
  final budgetBytes = MediaCacheBudgetRegistry.bytes;
  if (total <= budgetBytes) return;
  entries.sort((left, right) => left.modified.compareTo(right.modified));
  for (final entry in entries) {
    if (total <= budgetBytes) break;
    if (MediaCacheLeaseRegistry.shared.isLeased(entry.file.path)) continue;
    final removed = await _safeDelete(entry.file);
    if (removed) total -= entry.size;
  }
}

Future<List<({File file, int size, String kind, DateTime modified})>>
_managedEntries() async {
  final entries = <({File file, int size, String kind, DateTime modified})>[];
  final support = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;

  await _scanDirectory(
    Directory('${support.path}${sep}media_cache_v1'),
    entries,
    (name) {
      if (name.startsWith('image-')) return 'image';
      if (name.startsWith('voice-')) return 'voice';
      if (name.startsWith('stickerGif-')) return 'stickerGif';
      return 'temporary';
    },
  );
  await _scanDirectory(
    Directory('${support.path}${sep}video_cache_v1'),
    entries,
    (name) => name.endsWith('.video') ? 'video' : 'temporary',
  );
  await _scanDirectory(
    Directory('${support.path}${sep}media_transfer_cache_v1'),
    entries,
    (name) => name.endsWith('.part') ? 'temporary' : 'file',
  );
  await _scanDirectory(
    Directory('${support.path}${sep}DD${sep}transfers'),
    entries,
    (name) => name.endsWith('.part') ? 'temporary' : 'file',
  );

  try {
    final temporary = await getTemporaryDirectory();
    await _scanDirectory(
      Directory('${temporary.path}${sep}DD'),
      entries,
      (_) => 'temporary',
      recursive: true,
    );
  } catch (_) {
    // Temporary directory enumeration is best-effort.
  }
  return entries;
}

Future<void> _scanDirectory(
  Directory directory,
  List<({File file, int size, String kind, DateTime modified})> output,
  String Function(String fileName) classify, {
  bool recursive = false,
}) async {
  try {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        output.add((
          file: entity,
          size: stat.size,
          kind: classify(entity.uri.pathSegments.isEmpty
              ? entity.path
              : entity.uri.pathSegments.last),
          modified: stat.modified,
        ));
      } catch (_) {}
    }
  } catch (_) {
    // A transient file lock or missing directory must not break settings.
  }
}

Future<bool> _safeDelete(File file) async {
  if (MediaCacheLeaseRegistry.shared.isLeased(file.path)) return false;
  try {
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  } on FileSystemException {
    // Active OS/media handles may temporarily lock a file on Windows.
    return false;
  }
}
