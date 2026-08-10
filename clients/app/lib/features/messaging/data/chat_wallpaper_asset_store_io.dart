import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

abstract interface class ChatWallpaperAssetStore {
  Future<String> save(Uint8List bytes);
  Future<Uint8List?> read(String reference);
  Future<void> delete(String reference);
}

ChatWallpaperAssetStore createChatWallpaperAssetStore(String userId) =>
    _IoChatWallpaperAssetStore(userId);

final class _IoChatWallpaperAssetStore implements ChatWallpaperAssetStore {
  _IoChatWallpaperAssetStore(this.userId);

  final String userId;

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final safeUser = userId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}DD${Platform.pathSeparator}chat-backgrounds${Platform.pathSeparator}$safeUser',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<String> save(Uint8List bytes) async {
    final directory = await _directory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}wallpaper-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<Uint8List?> read(String reference) async {
    final file = File(reference);
    if (!await file.exists()) return null;
    try {
      return Uint8List.fromList(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete(String reference) async {
    if (reference.trim().isEmpty) return;
    try {
      final directory = await _directory();
      final file = File(reference);
      final canonicalDirectory = directory.absolute.path;
      final canonicalFile = file.absolute.path;
      if (!canonicalFile.startsWith(canonicalDirectory)) return;
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Appearance cleanup must not break the rest of the app.
    }
  }
}
