enum DdQrKind { user, group, login }

final class DdQrPayload {
  const DdQrPayload({
    required this.kind,
    required this.instance,
    this.userId,
    this.nonce,
  });

  final DdQrKind kind;
  final Uri instance;
  final String? userId;
  final String? nonce;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _nonce = RegExp(r'^[A-Za-z0-9_-]{43}$');

  static DdQrPayload parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'dd' ||
        uri.host != 'qr' ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'v1') {
      throw const FormatException('这不是 DD 二维码。');
    }
    final rawInstance = uri.queryParameters['instance'];
    final instance = rawInstance == null ? null : Uri.tryParse(rawInstance);
    if (instance == null ||
        !instance.isAbsolute ||
        (instance.scheme != 'https' && instance.scheme != 'http') ||
        instance.host.isEmpty ||
        instance.userInfo.isNotEmpty ||
        instance.hasQuery ||
        instance.hasFragment) {
      throw const FormatException('二维码中的 DD 实例地址无效。');
    }
    final normalizedInstance = _normalizeOrigin(instance);
    final type = uri.pathSegments.last;
    switch (type) {
      case 'user':
        final userId = uri.queryParameters['userId']?.trim() ?? '';
        if (!_uuid.hasMatch(userId)) {
          throw const FormatException('用户二维码缺少有效 userId。');
        }
        return DdQrPayload(
          kind: DdQrKind.user,
          instance: normalizedInstance,
          userId: userId,
        );
      case 'group':
        final nonce = uri.queryParameters['nonce']?.trim() ?? '';
        if (!_nonce.hasMatch(nonce)) {
          throw const FormatException('群二维码凭证无效。');
        }
        return DdQrPayload(
          kind: DdQrKind.group,
          instance: normalizedInstance,
          nonce: nonce,
        );
      case 'login':
        final nonce = uri.queryParameters['nonce']?.trim() ?? '';
        if (!_nonce.hasMatch(nonce)) {
          throw const FormatException('登录二维码凭证无效。');
        }
        return DdQrPayload(
          kind: DdQrKind.login,
          instance: normalizedInstance,
          nonce: nonce,
        );
      default:
        throw const FormatException('当前客户端不支持这种 DD 二维码。');
    }
  }

  bool belongsTo(Uri origin) => _normalizeOrigin(origin) == instance;

  static Uri _normalizeOrigin(Uri origin) {
    if (!origin.isAbsolute ||
        (origin.scheme != 'https' && origin.scheme != 'http') ||
        origin.host.isEmpty) {
      throw const FormatException('DD 实例地址无效。');
    }
    return origin.replace(path: '', query: null, fragment: null);
  }
}
