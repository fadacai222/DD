import '../data/sticker_api_client.dart';

String stickerOperationErrorText(Object error) {
  if (error is StickerApiException) {
    final message = switch (error.code) {
      'TELEGRAM_STICKER_RELAY_NOT_CONFIGURED' =>
        '服务端未配置 Telegram sticker relay，请联系管理员完成配置后重试。',
      'TELEGRAM_STICKER_RELAY_AUTH_FAILED' =>
        '服务端的 Telegram sticker relay 鉴权失败，请联系管理员检查配置。',
      'TELEGRAM_STICKER_RELAY_RATE_LIMITED' => 'Telegram 当前正在限流，请稍后再试。',
      'TELEGRAM_STICKER_RELAY_TIMEOUT' => 'Telegram 贴纸中继请求超时，请稍后重试。',
      'TELEGRAM_STICKER_RELAY_UNAVAILABLE' => 'Telegram 贴纸中继暂时不可用，请稍后重试。',
      'TELEGRAM_STICKER_PACK_NOT_FOUND' => '没有找到这个 Telegram 贴纸包，请检查链接或贴纸包名称。',
      'TELEGRAM_STICKER_FORMAT_UNSUPPORTED' =>
        '这个贴纸包里没有可导入的贴纸；支持静态 WebP/PNG、动态 TGS、视频 WebM。',
      'TELEGRAM_STICKER_TOO_LARGE' => '贴纸包中有文件超过当前实例允许的大小。',
      'TELEGRAM_STICKER_INVALID' => 'Telegram 返回的贴纸文件无效，请稍后重试或换一个贴纸包。',
      'STICKER_RATE_LIMITED' => '导入操作过于频繁，请稍后重试。',
      'STICKER_REQUEST_TIMEOUT' => '网络请求超时，请检查网络后重试。',
      'STICKER_NETWORK_ERROR' => '无法连接 DD 表情服务，请检查网络后重试。',
      'STICKER_INTERNAL_ERROR' => 'DD 表情服务暂时异常，请稍后重试。',
      _ when error.statusCode >= 500 => 'DD 表情服务暂时异常，请稍后重试。',
      _ => error.message,
    };
    final diagnostic = error.statusCode > 0
        ? '${error.code} · HTTP ${error.statusCode}'
        : error.code;
    return '$message\n$diagnostic';
  }
  if (error is FormatException) return error.message.toString();
  if (error is String) return error;
  return error.toString();
}
