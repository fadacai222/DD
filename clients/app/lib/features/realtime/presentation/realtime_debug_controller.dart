import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../data/realtime_client_gateway.dart';
import '../domain/debug_log_entry.dart';
import '../domain/realtime_gateway.dart';

final class RealtimeDebugController extends ChangeNotifier {
  RealtimeDebugController({
    RealtimeGatewayFactory? gatewayFactory,
    String? clientId,
    DateTime Function()? now,
  }) : _gatewayFactory = gatewayFactory ?? _defaultGatewayFactory,
       clientId = clientId ?? _newClientId(),
       _now = now ?? DateTime.now;

  static const int maxLogEntries = 200;

  final RealtimeGatewayFactory _gatewayFactory;
  final DateTime Function() _now;
  final String clientId;

  final List<DebugLogEntry> _logs = <DebugLogEntry>[];
  RealtimeGateway? _gateway;
  // These subscriptions are cancelled together in _releaseGateway.
  // ignore: cancel_subscriptions
  StreamSubscription<RealtimeConnectionState>? _stateSubscription;
  // ignore: cancel_subscriptions
  StreamSubscription<RealtimeEvent>? _eventSubscription;
  // ignore: cancel_subscriptions
  StreamSubscription<Object>? _errorSubscription;

  RealtimeConnectionState _connectionState =
      RealtimeConnectionState.disconnected;
  bool _isBusy = false;
  bool _closed = false;
  Uri? _activeServer;
  String? _healthSummary;

  Uri? get activeServer => _activeServer;

  RealtimeConnectionState get connectionState => _connectionState;

  String? get healthSummary => _healthSummary;

  bool get isBusy => _isBusy;

  bool get isConnected => _connectionState == RealtimeConnectionState.connected;

  List<DebugLogEntry> get logs => List<DebugLogEntry>.unmodifiable(_logs);

  Future<bool> checkHealth(String rawServerUrl) async {
    final uri = _parseServerUri(rawServerUrl);
    if (uri == null) {
      _addLog(DebugLogLevel.error, '服务器地址无效：仅支持 http/https，且不能包含路径、查询参数或账号信息。');
      return false;
    }
    if (!_beginAction()) {
      return false;
    }

    final probe = _gatewayFactory(uri, '$clientId-health');
    try {
      _addLog(DebugLogLevel.info, '检查 ${uri.origin} 的健康状态…');
      final result = await probe.fetchHealth();
      final status = result['status']?.toString() ?? 'unknown';
      final service = result['service']?.toString() ?? 'unknown-service';
      _healthSummary = '$service · $status';
      _addLog(DebugLogLevel.success, '健康检查通过：$_healthSummary');
      return true;
    } catch (error) {
      _healthSummary = null;
      _addLog(DebugLogLevel.error, '健康检查失败：${_safeError(error)}');
      return false;
    } finally {
      await probe.dispose();
      _endAction();
    }
  }

  Future<bool> connect(String rawServerUrl) async {
    final uri = _parseServerUri(rawServerUrl);
    if (uri == null) {
      _addLog(DebugLogLevel.error, '服务器地址无效：例如 http://127.0.0.1:18473。');
      return false;
    }
    if (!_beginAction()) {
      return false;
    }

    try {
      await _releaseGateway();
      final gateway = _gatewayFactory(uri, clientId);
      _gateway = gateway;
      _activeServer = uri;
      _listenTo(gateway);

      _addLog(DebugLogLevel.info, '正在连接 ${uri.origin}…');
      await gateway.connect();
      return true;
    } catch (error) {
      _addLog(DebugLogLevel.error, '连接失败：${_safeError(error)}');
      await _releaseGateway();
      return false;
    } finally {
      _endAction();
    }
  }

  Future<void> disconnect() async {
    final gateway = _gateway;
    if (gateway == null) {
      _addLog(DebugLogLevel.warning, '当前没有可断开的连接。');
      return;
    }
    if (!_beginAction()) {
      return;
    }

    try {
      _addLog(DebugLogLevel.info, '正在断开实时连接…');
      await gateway.disconnect();
      _addLog(DebugLogLevel.success, '实时连接已断开。');
    } catch (error) {
      _addLog(DebugLogLevel.error, '断开连接失败：${_safeError(error)}');
    } finally {
      await _releaseGateway();
      _endAction();
    }
  }

  bool sendPing() {
    final gateway = _gateway;
    if (gateway == null || !isConnected) {
      _addLog(DebugLogLevel.warning, '连接建立后才能发送 Ping。');
      return false;
    }

    try {
      gateway.sendPing();
      _addLog(DebugLogLevel.info, '已发送 Ping，等待 Pong。');
      return true;
    } catch (error) {
      _addLog(DebugLogLevel.error, '发送 Ping 失败：${_safeError(error)}');
      return false;
    }
  }

  void clearLogs() {
    if (_logs.isEmpty) {
      return;
    }
    _logs.clear();
    _notify();
  }

  Future<void> shutdown() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _releaseGateway(notify: false);
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }

  void _listenTo(RealtimeGateway gateway) {
    _stateSubscription = gateway.states.listen((state) {
      _connectionState = state;
      switch (state) {
        case RealtimeConnectionState.connecting:
          _addLog(DebugLogLevel.info, 'WebSocket 正在握手。');
        case RealtimeConnectionState.connected:
          _addLog(DebugLogLevel.success, 'WebSocket 已连接。');
        case RealtimeConnectionState.disconnected:
          _addLog(DebugLogLevel.warning, 'WebSocket 已断开，客户端将按策略重连。');
      }
      _notify();
    });
    _eventSubscription = gateway.events.listen(_handleEvent);
    _errorSubscription = gateway.errors.listen(
      (error) => _addLog(DebugLogLevel.error, '实时通道错误：${_safeError(error)}'),
    );
  }

  void _handleEvent(RealtimeEvent event) {
    final requestPart = event.requestId.isEmpty
        ? ''
        : ' · request=${event.requestId}';
    final realtimeError = event.error;
    final errorPart = realtimeError == null
        ? ''
        : ' · ${realtimeError.code}: ${realtimeError.message}';
    final payloadPart = event.payload.isEmpty
        ? ''
        : ' · payload=${_compactJson(event.payload)}';

    _addLog(
      realtimeError == null ? DebugLogLevel.success : DebugLogLevel.error,
      '#${event.eventId} ${event.type}$requestPart$errorPart$payloadPart',
    );
  }

  bool _beginAction() {
    if (_closed || _isBusy) {
      if (!_closed) {
        _addLog(DebugLogLevel.warning, '上一项操作尚未结束。');
      }
      return false;
    }
    _isBusy = true;
    _notify();
    return true;
  }

  void _endAction() {
    if (_closed) {
      return;
    }
    _isBusy = false;
    _notify();
  }

  Future<void> _releaseGateway({bool notify = true}) async {
    final subscriptions = <StreamSubscription<dynamic>?>[
      _stateSubscription,
      _eventSubscription,
      _errorSubscription,
    ];
    _stateSubscription = null;
    _eventSubscription = null;
    _errorSubscription = null;

    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }

    final gateway = _gateway;
    _gateway = null;
    if (gateway != null) {
      await gateway.dispose();
    }

    _connectionState = RealtimeConnectionState.disconnected;
    _activeServer = null;
    if (notify) {
      _notify();
    }
  }

  void _addLog(DebugLogLevel level, String message) {
    if (_closed) {
      return;
    }
    _logs.add(DebugLogEntry(timestamp: _now(), level: level, message: message));
    if (_logs.length > maxLogEntries) {
      _logs.removeRange(0, _logs.length - maxLogEntries);
    }
    _notify();
  }

  void _notify() {
    if (!_closed) {
      notifyListeners();
    }
  }

  static RealtimeGateway _defaultGatewayFactory(Uri baseUri, String clientId) {
    return RealtimeClientGateway(baseUri: baseUri, clientId: clientId);
  }

  static Uri? _parseServerUri(String rawValue) {
    final value = rawValue.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }

    return uri.replace(path: '', query: null, fragment: null);
  }

  static String _compactJson(Object? value) {
    final encoded = jsonEncode(value);
    if (encoded.length <= 240) {
      return encoded;
    }
    return '${encoded.substring(0, 237)}…';
  }

  static String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 300 ? text : '${text.substring(0, 297)}…';
  }

  static String _newClientId() {
    return 'debug-${DateTime.now().microsecondsSinceEpoch}';
  }
}
