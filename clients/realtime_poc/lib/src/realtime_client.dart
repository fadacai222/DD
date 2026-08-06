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
    http.Client? httpClient,
    WebSocketChannelFactory? channelFactory,
    Duration connectTimeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _channelFactory =
           channelFactory ?? ((uri) => WebSocketChannel.connect(uri)),
       _connectTimeout = connectTimeout;

  final Uri baseUri;
  final String clientId;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final WebSocketChannelFactory _channelFactory;
  final Duration _connectTimeout;
  final EventCursor _cursor = EventCursor();

  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<RealtimeConnectionState> _stateController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
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
      await channel.ready.timeout(_connectTimeout);

      if (_stopped) {
        await channel.sink.close(status.normalClosure, 'client stopped');
        return;
      }

      _channel = channel;
      _reconnectAttempt = 0;
      _subscription = channel.stream.listen(
        _handleMessage,
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
          },
        }),
      );
      _setState(RealtimeConnectionState.connected);
      candidate = null;
    } catch (error) {
      final failedChannel = candidate;
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
      if (!_errorController.isClosed) {
        _errorController.add(error);
      }
      _setState(RealtimeConnectionState.disconnected);
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _handleMessage(dynamic rawMessage) {
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

    _channel = null;
    _subscription = null;
    _setState(RealtimeConnectionState.disconnected);
    _scheduleReconnect();
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
    return baseUri.replace(
      scheme: scheme,
      path: '/ws',
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
