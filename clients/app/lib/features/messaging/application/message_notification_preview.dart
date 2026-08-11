String messageNotificationPreview({
  required String messageType,
  String text = '',
}) {
  final normalizedType = messageType.trim().toUpperCase();
  final normalizedText = text.trim();

  if (normalizedType == 'TEXT' || normalizedType == 'SYSTEM') {
    return normalizedText.isEmpty ? '新消息' : normalizedText;
  }

  return switch (normalizedType) {
    'IMAGE' => '图片',
    'GIF' => 'GIF',
    'STICKER' => '贴纸',
    'STICKER_PACK' => '表情包',
    'VIDEO' => '视频',
    'VOICE' => '语音消息',
    'FILE' => '文件',
    _ => '新消息',
  };
}
