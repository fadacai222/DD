import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/moments_api_client.dart';

final class MomentActivityController extends ChangeNotifier {
  MomentActivityController({
    required this.origin,
    required String accessToken,
    required MomentActivityGateway gateway,
  }) {
    _accessToken = accessToken;
    _gateway = gateway;
  }

  final Uri origin;
  late final MomentActivityGateway _gateway;
  late String _accessToken;
  int _unreadCount = 0;
  int _requestSerial = 0;
  bool _disposed = false;

  int get unreadCount => _unreadCount;

  void updateAccessToken(String nextToken) {
    final normalized = nextToken.trim();
    if (normalized.isEmpty || normalized == _accessToken) return;
    _accessToken = normalized;
  }

  Future<void> refresh() async {
    if (_disposed || _accessToken.trim().isEmpty) return;
    final serial = ++_requestSerial;
    try {
      final summary = await _gateway.getActivitySummary(
        origin: origin,
        accessToken: _accessToken,
      );
      if (_disposed || serial != _requestSerial) return;
      _setUnreadCount(summary.unreadCount);
    } catch (_) {
      // The durable server count will be retried on realtime hints, resume or the
      // next shell entry. Do not erase a known badge because one refresh failed.
    }
  }

  Future<void> markRead() async {
    if (_disposed || _accessToken.trim().isEmpty) return;
    final previous = _unreadCount;
    final serial = ++_requestSerial;
    _setUnreadCount(0);
    try {
      final summary = await _gateway.markActivityRead(
        origin: origin,
        accessToken: _accessToken,
      );
      if (_disposed || serial != _requestSerial) return;
      _setUnreadCount(summary.unreadCount);
    } catch (_) {
      if (_disposed || serial != _requestSerial) return;
      _setUnreadCount(previous);
      unawaited(refresh());
    }
  }

  void handleRealtimeReason(String reason) {
    if (_disposed || !reason.trim().toLowerCase().startsWith('moment-')) return;
    unawaited(refresh());
  }

  void _setUnreadCount(int value) {
    final normalized = value < 0 ? 0 : value;
    if (_unreadCount == normalized || _disposed) return;
    _unreadCount = normalized;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _requestSerial++;
    super.dispose();
  }
}
