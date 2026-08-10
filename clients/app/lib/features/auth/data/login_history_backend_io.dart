import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> _historyFile() async {
  final directory = await getApplicationSupportDirectory();
  final folder = Directory(
    '${directory.path}${Platform.pathSeparator}account_history',
  );
  if (!await folder.exists()) await folder.create(recursive: true);
  return File('${folder.path}${Platform.pathSeparator}login_history.json');
}

Future<String?> readLoginHistoryFile() async {
  final file = await _historyFile();
  if (!await file.exists()) return null;
  try {
    return await file.readAsString();
  } on FileSystemException {
    return null;
  }
}

Future<void> writeLoginHistoryFile(String content) async {
  final file = await _historyFile();
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(content, flush: true);
  if (await file.exists()) {
    try {
      await file.delete();
    } on FileSystemException {
      // Antivirus/indexers may briefly hold the destination on Windows.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (await file.exists()) await file.delete();
    }
  }
  await temp.rename(file.path);
}
