bool isAllowedNotificationAvatarUrl(Uri uri) {
  if (uri.host.isEmpty) return false;
  if (uri.scheme == 'https') return true;
  return uri.scheme == 'http' && _isPrivateDevelopmentHost(uri.host);
}

bool _isPrivateDevelopmentHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized == 'localhost' || normalized == '::1') return true;
  final parts = normalized.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList(growable: false);
  if (octets.any((value) => value == null || value < 0 || value > 255)) {
    return false;
  }
  final a = octets[0]!;
  final b = octets[1]!;
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}
