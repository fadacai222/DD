import 'dart:io';
import 'dart:typed_data';

Future<Uri?> writeNotificationAvatarFile(String userId, Uint8List bytes) async {
  if (!Platform.isWindows || bytes.isEmpty) return null;
  try {
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}dd-notification-avatars',
    );
    await directory.create(recursive: true);
    final safeId = userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${directory.path}${Platform.pathSeparator}$safeId.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return Uri.file(file.absolute.path, windows: true);
  } on FileSystemException {
    return null;
  }
}
