final RegExp _telegramStickerSetName = RegExp(r'^[A-Za-z0-9_]{1,64}$');

String parseTelegramStickerSetName(String raw) {
  final value = raw.trim();
  if (_telegramStickerSetName.hasMatch(value)) return value;

  final uri = Uri.tryParse(value);
  if (uri == null || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    throw const FormatException('Telegram 贴纸包链接无效。');
  }

  if (uri.scheme == 'tg') {
    if (uri.host != 'addstickers' || uri.path.isNotEmpty) {
      throw const FormatException('只支持 Telegram addstickers 链接。');
    }
    if (uri.queryParameters.length != 1 ||
        !uri.queryParameters.containsKey('set')) {
      throw const FormatException('Telegram 贴纸包链接缺少 set 参数。');
    }
    return _validateSetName(uri.queryParameters['set'] ?? '');
  }

  if (uri.scheme != 'https') {
    throw const FormatException('Telegram 贴纸包链接必须使用 HTTPS。');
  }
  final host = uri.host.toLowerCase();
  if (host != 't.me' && host != 'telegram.me' && host != 'www.telegram.me') {
    throw const FormatException('只允许导入 Telegram 官方贴纸包链接。');
  }
  if (uri.hasQuery) {
    throw const FormatException('Telegram 贴纸包链接不能包含额外参数。');
  }
  final segments = uri.pathSegments.where((value) => value.isNotEmpty).toList();
  if (segments.length != 2 || segments.first.toLowerCase() != 'addstickers') {
    throw const FormatException('只支持 /addstickers/<setName> 链接。');
  }
  return _validateSetName(segments[1]);
}

String _validateSetName(String raw) {
  final value = raw.trim();
  if (!_telegramStickerSetName.hasMatch(value)) {
    throw const FormatException('Telegram 贴纸包名称无效。');
  }
  return value;
}
