import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'event_cursor.dart';
import 'realtime_event.dart';

typedef WebSocketChannelFactory = WebSocketChannel Function(Uri uri);

enum RealtimeConnectionState { disconnected, connecting, connected }

final class RealtimeClient {
  RealtimeClient({
    required this.baseUri,
    required this.clientId,
    this.webSocketPath = '/ws',
    this.accessToken,
    this.protocolVersion,
    http.Client? httpClient,
    WebSocketChannelFactory? channelFactory,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration heartbeatInterval = const Duration(seconds: 5),
    Duration heartbeatTimeout = const Duration(seconds: 5),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _channelFactory =
           channelFactory ?? ((uri) => WebSocketChannel.connect(uri)),
       _connectTimeout = connectTimeout,
       _heartbeatInterval = heartbeatInterval,
       _heartbeatTimeout = heartbeatTimeout;

  final Uri baseUri;
  final String clientId;
  final String webSocketPath;
  final String? accessToken;
  final String? protocolVersion;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final WebSocketChannelFactory _channelFactory;
  final Duration _connectTimeout;
  final Duration _heartbeatInterval;
  final Duration _heartbeatTimeout;
  final EventCursor _cursor = EventCursor();

  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<RealtimeConnectionState> _stateController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  WebSocketChannel? _channel;
  WebSocketChannel? _pendingChannel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Timer? _connectTimeoutTimer;
  Completer<void>? _connectReadyCompleter;
  Timer? _heartbeatTimer;
  Timer? _heartbeatDeadlineTimer;
  String? _pendingHeartbeatRequestId;
  bool _stopped = true;
  bool _isConnecting = false;
  int _reconnectAttempt = 0;
  RealtimeConnectionState _state = RealtimeConnectionState.disconnected;

  Stream<RealtimeEvent> get events => _eventController.stream;

  Stream<RealtimeConnectionState> get states => _stateController.stream;

  Stream<Object> get errors => _errorController.stream;

  RealtimeConnectionState get state => _state;

  int get lastEventId => _cursor.lastEventId;

  Future<Map<String, dynamic>> fetchHealth() async {
    final response = await _httpClient
        .get(baseUri.resolve('/health'))
        .timeout(_connectTimeout);
    if (response.statusCode != 200) {
      throw StateError('Health check failed with HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Health response must be a JSON object');
    }
    return decoded;
  }

  Future<void> connect() async {
    _stopped = false;
    _reconnectTimer?.cancel();
    await _connectOnce();
  }

  Future<void> disconnect() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
    final readyCompleter = _connectReadyCompleter;
    _connectReadyCompleter = null;
    if (readyCompleter != null && !readyCompleter.isCompleted) {
      readyCompleter.completeError(StateError('Realtime client stopped'));
    }
    final pendingChannel = _pendingChannel;
    _pendingChannel = null;
    if (pendingChannel != null) {
      try {
        await pendingChannel.sink.close(status.normalClosure, 'client shutdown');
      } catch (_) {
        // A connection still in handshake may not accept a clean close.
      }
    }
    _stopHeartbeat();

    await _subscription?.cancel();
    _subscription = null;

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      await channel.sink.close(status.normalClosure, 'client shutdown');
    }

    _setState(RealtimeConnectionState.disconnected);
  }

  void sendPing() {
    final channel = _channel;
    if (_state != RealtimeConnectionState.connected || channel == null) {
      throw StateError('Realtime client is not connected');
    }

    channel.sink.add(
      jsonEncode(<String, dynamic>{
        'type': 'ping',
        'requestId': 'ping-${DateTime.now().microsecondsSinceEpoch}',
      }),
    );
  }

  Future<void> dispose() async {
    await disconnect();
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    await _eventController.close();
    await _stateController.close();
    await _errorController.close();
  }

  Future<void> _connectOnce() async {
    if (_stopped || _isConnecting) {
      return;
    }

    _isConnecting = true;
    _setState(RealtimeConnectionState.connecting);
    WebSocketChannel? candidate;

    try {
      final channel = _channelFactory(_webSocketUri());
      candidate = channel;
      _pendingChannel = channel;
      await _waitUntilReady(channel);
      if (identical(_pendingChannel, channel)) {
        _pendingChannel = null;
      }

      if (_stopped) {
        await channel.sink.close(status.normalClosure, 'client stopped');
        return;
      }

      _channel = channel;
      _reconnectAttempt = 0;
      _subscription = channel.stream.listen(
        (message) => _handleMessage(channel, message),
        onError: (Object error, StackTrace stackTrace) {
          if (!_errorController.isClosed) {
            _errorController.add(error);
          }
          _handleDisconnectedChannel(channel);
        },
        onDone: () => _handleDisconnectedChannel(channel),
        cancelOnError: false,
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'type': 'hello',
          'requestId': 'hello-${DateTime.now().microsecondsSinceEpoch}',
          'payload': <String, dynamic>{
            'clientId': clientId,
            'lastEventId': _cursor.lastEventId,
            if (accessToken != null && accessToken!.trim().isNotEmpty)
              'accessToken': accessToken!.trim(),
            if (protocolVersion != null && protocolVersion!.trim().isNotEmpty)
              'protocolVersion': protocolVersion!.trim(),
          },
        }),
      );
      _setState(RealtimeConnectionState.connected);
      _startHeartbeat(channel);
      candidate = null;
    } catch (error) {
      final failedChannel = candidate;
      if (failedChannel != null && identical(_pendingChannel, failedChannel)) {
        _pendingChannel = null;
      }
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = null;
      _connectReadyCompleter = null;
      if (failedChannel != null) {
        if (identical(_channel, failedChannel)) {
          _channel = null;
        }
        try {
          await failedChannel.sink.close(
            status.normalClosure,
            'connect failed',
          );
        } catch (_) {
          // Best effort cleanup after a failed handshake or setup.
        }
      }
      if (!_stopped && !_errorController.isClosed) {
        _errorController.add(error);
      }
      _setState(RealtimeConnectionState.disconnected);
      _scheduleReconnect();
    } finally {
      _connectTimeoutTimer?.cancel();
      _connectTimeoutTimer = null;
      _connectReadyCompleter = null;
      _isConnecting = false;
    }
  }

  Future<void> _waitUntilReady(WebSocketChannel channel) {
    final completer = Completer<void>();
    _connectReadyCompleter = completer;
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(_connectTimeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('Realtime connection timed out', _connectTimeout),
        );
      }
    });
    channel.ready.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  void _handleMessage(WebSocketChannel channel, dynamic rawMessage) {
    if (!identical(_channel, channel)) {
      return;
    }
    if (rawMessage is! String) {
      if (!_errorController.isClosed) {
        _errorController.add(
          const FormatException('Binary WebSocket messages are not supported'),
        );
      }
      return;
    }

    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Realtime event must be a JSON object');
      }

      final event = RealtimeEvent.fromJson(decoded);
      if (event.type == 'pong' &&
          event.requestId.isNotEmpty &&
          event.requestId == _pendingHeartbeatRequestId) {
        _heartbeatDeadlineTimer?.cancel();
        _heartbeatDeadlineTimer = null;
        _pendingHeartbeatRequestId = null;
      }
      if (!_cursor.accept(event.eventId)) {
        return;
      }
      if (!_eventController.isClosed) {
        _eventController.add(event);
      }
    } catch (error) {
      if (!_errorController.isClosed) {
        _errorController.add(error);
      }
    }
  }

  void _handleDisconnectedChannel(WebSocketChannel channel) {
    if (!identical(_channel, channel)) {
      return;
    }

    _stopHeartbeat();
    _channel = null;
    _subscription = null;
    _setState(RealtimeConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _startHeartbeat(WebSocketChannel channel) {
    _stopHeartbeat();
    if (_heartbeatInterval <= Duration.zero ||
        _heartbeatTimeout <= Duration.zero) {
      return;
    }

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_stopped ||
          _state != RealtimeConnectionState.connected ||
          !identical(_channel, channel) ||
          _pendingHeartbeatRequestId != null) {
        return;
      }

      final requestId = 'heartbeat-${DateTime.now().microsecondsSinceEpoch}';
      _pendingHeartbeatRequestId = requestId;
      try {
        channel.sink.add(
          jsonEncode(<String, dynamic>{'type': 'ping', 'requestId': requestId}),
        );
      } catch (error) {
        unawaited(_forceReconnect(channel, error));
        return;
      }

      _heartbeatDeadlineTimer = Timer(_heartbeatTimeout, () {
        if (_pendingHeartbeatRequestId != requestId ||
            !identical(_channel, channel)) {
          return;
        }
        _pendingHeartbeatRequestId = null;
        _heartbeatDeadlineTimer = null;
        unawaited(
          _forceReconnect(
            channel,
            TimeoutException('Realtime heartbeat timed out', _heartbeatTimeout),
          ),
        );
      });
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatDeadlineTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatDeadlineTimer = null;
    _pendingHeartbeatRequestId = null;
  }

  Future<void> _forceReconnect(WebSocketChannel channel, Object error) async {
    if (_stopped || !identical(_channel, channel)) {
      return;
    }

    if (!_errorController.isClosed) {
      _errorController.add(error);
    }
    _stopHeartbeat();

    final subscription = _subscription;
    _subscription = null;
    _channel = null;
    _setState(RealtimeConnectionState.disconnected);
    _scheduleReconnect();

    try {
      await subscription?.cancel();
    } catch (_) {
      // Best effort cleanup; the reconnect path must continue.
    }
    try {
      await channel.sink.close(status.normalClosure, 'heartbeat timeout');
    } catch (_) {
      // A half-open socket may refuse to close cleanly.
    }
  }

  void _scheduleReconnect() {
    if (_stopped || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectAttempt++;
    final exponent = min(_reconnectAttempt - 1, 5);
    final delaySeconds = min(30, 1 << exponent);
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      unawaited(_connectOnce());
    });
  }

  Uri _webSocketUri() {
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final path = webSocketPath.startsWith('/')
        ? webSocketPath
        : '/$webSocketPath';
    return baseUri.replace(
      scheme: scheme,
      path: path,
      query: null,
      fragment: null,
    );
  }

  void _setState(RealtimeConnectionState nextState) {
    if (_state == nextState) {
      return;
    }
    _state = nextState;
    if (!_stateController.isClosed) {
      _stateController.add(nextState);
    }
  }
}
