import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../core/sound/app_audio_activity.dart';
import '../data/call_audio_session_controller.dart';
import '../data/call_platform_service.dart';
import '../data/http_call_token_provider.dart';
import '../domain/call_log_entry.dart';
import '../domain/call_media_gateway.dart';
import '../domain/call_token.dart';

typedef CallConnectivityCheckRunner =
    Future<List<CheckInfo>> Function(CallToken credentials);

final class CallDebugController extends ChangeNotifier
    implements CallMediaGateway {
  CallDebugController({
    CallTokenProvider? tokenProvider,
    CallConnectivityCheckRunner? connectivityCheckRunner,
    CallPlatformGateway? platformGateway,
    CallAudioSessionController? audioSession,
    AppAudioActivity? audioActivity,
    DateTime Function()? now,
  }) : _tokenProvider = tokenProvider ?? HttpCallTokenProvider(),
       _connectivityCheckRunner =
           connectivityCheckRunner ?? _runLiveKitConnectivityChecks,
       _platformGateway = platformGateway ?? CallPlatformService.shared,
       _audioSession = audioSession ?? CallAudioSessionController(),
       _audioActivity = audioActivity ?? AppAudioActivity.shared,
       _now = now ?? DateTime.now {
    _platformSubscription = _platformGateway.events.listen(_handlePlatformEvent);
  }

  static const int maxLogEntries = 150;
  static final RegExp _safeIdentifier = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );

  final CallTokenProvider _tokenProvider;
  final CallConnectivityCheckRunner _connectivityCheckRunner;
  final CallPlatformGateway _platformGateway;
  final CallAudioSessionController _audioSession;
  final AppAudioActivity _audioActivity;
  final DateTime Function() _now;
  final List<CallLogEntry> _logs = <CallLogEntry>[];
  final StreamController<CallMediaConnectionEvent> _connectionEvents =
      StreamController<CallMediaConnectionEvent>.broadcast(sync: true);
  final Object _mediaAudioOwner = Object();
  final Object _systemAudioOwner = Object();

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  StreamSubscription<CallPlatformEvent>? _platformSubscription;
  bool _busy = false;
  bool _connected = false;
  bool _microphoneEnabled = false;
  bool _cameraEnabled = false;
  bool _cameraSuspended = false;
  bool _frontCamera = true;
  bool _systemCallManaged = false;
  bool _closed = false;
  String? _roomName;

  Room? get room => _room;
  bool get busy => _busy;
  @override
  bool get connected => _connected;
  @override
  bool get microphoneEnabled => _microphoneEnabled;
  @override
  bool get cameraEnabled => _cameraEnabled;
  @override
  bool get speakerPreferred => _audioSession.speakerPreferred;
  @override
  String get audioRouteLabel => _audioSession.route.label;
  @override
  Stream<CallMediaConnectionEvent> get connectionEvents =>
      _connectionEvents.stream;
  @override
  String? get lastError {
    for (final entry in _logs.reversed) {
      if (entry.level == CallLogLevel.error) return entry.message;
    }
    return null;
  }

  bool get frontCamera => _frontCamera;
  String? get roomName => _roomName;
  List<CallLogEntry> get logs => List.unmodifiable(_logs);
  List<RemoteParticipant> get remoteParticipants =>
      _room?.remoteParticipants.values.toList(growable: false) ?? const [];

  VideoTrack? get localVideoTrack {
    final participant = _room?.localParticipant;
    if (participant == null) return null;
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track is VideoTrack && !publication.isScreenShare) {
        return track;
      }
    }
    return null;
  }

  Future<bool> join({
    required String tokenApiBaseUrl,
    required String roomName,
    required String participantIdentity,
    required String participantName,
    required bool enableMicrophone,
    required bool enableCamera,
  }) async {
    if (!_beginAction()) return false;

    final apiBaseUri = _parseApiBaseUri(tokenApiBaseUrl);
    final normalizedRoom = roomName.trim();
    final normalizedIdentity = participantIdentity.trim();
    final normalizedName = participantName.trim();
    if (apiBaseUri == null ||
        !_safeIdentifier.hasMatch(normalizedRoom) ||
        !_safeIdentifier.hasMatch(normalizedIdentity) ||
        normalizedName.isEmpty ||
        normalizedName.runes.length > 80) {
      _addLog(
        CallLogLevel.error,
        '参数无效：服务地址需为 http/https；房间和身份只能使用字母、数字、点、下划线或短横线。',
      );
      _endAction();
      return false;
    }

    try {
      await _releaseRoom();
      _addLog(CallLogLevel.info, '正在向 ${apiBaseUri.origin} 申请短期通话令牌…');
      final credentials = await _tokenProvider.issue(
        apiBaseUri: apiBaseUri,
        roomName: normalizedRoom,
        participantIdentity: normalizedIdentity,
        participantName: normalizedName,
      );
      _addLog(
        CallLogLevel.success,
        '令牌已签发，有效至 ${credentials.expiresAt.toLocal()}。',
      );

      return await _connectWithCredentials(
        credentials: credentials,
        roomName: normalizedRoom,
        enableMicrophone: enableMicrophone,
        enableCamera: enableCamera,
      );
    } catch (error) {
      _addLog(CallLogLevel.error, '加入房间失败：${_safeError(error)}');
      await _releaseRoom();
      return false;
    } finally {
      _endAction();
    }
  }

  @override
  Future<bool> joinWithCredentials({
    required CallToken credentials,
    required String roomName,
    required bool enableMicrophone,
    required bool enableCamera,
  }) async {
    if (!_beginAction()) return false;
    final normalizedRoom = roomName.trim();
    if (!_safeIdentifier.hasMatch(normalizedRoom) ||
        credentials.participantToken.trim().isEmpty ||
        !credentials.serverUrl.isAbsolute ||
        (credentials.serverUrl.scheme != 'ws' &&
            credentials.serverUrl.scheme != 'wss')) {
      _addLog(CallLogLevel.error, '通话凭据无效，无法进入媒体房间。');
      _endAction();
      return false;
    }

    try {
      await _releaseRoom();
      _addLog(
        CallLogLevel.success,
        '已取得受限通话令牌，有效至 ${credentials.expiresAt.toLocal()}。',
      );
      return await _connectWithCredentials(
        credentials: credentials,
        roomName: normalizedRoom,
        enableMicrophone: enableMicrophone,
        enableCamera: enableCamera,
      );
    } catch (error) {
      _addLog(CallLogLevel.error, '进入通话失败：${_safeError(error)}');
      await _releaseRoom();
      return false;
    } finally {
      _endAction();
    }
  }

  Future<bool> runConnectivityDiagnostics({
    required String tokenApiBaseUrl,
    required String roomName,
    required String participantIdentity,
    required String participantName,
  }) async {
    if (_connected) {
      _addLog(CallLogLevel.warning, '请先离开当前房间，再运行网络/TURN 诊断。');
      return false;
    }
    if (!_beginAction()) return false;

    final apiBaseUri = _parseApiBaseUri(tokenApiBaseUrl);
    final normalizedRoom = roomName.trim();
    final normalizedIdentity = participantIdentity.trim();
    final normalizedName = participantName.trim();
    if (apiBaseUri == null ||
        !_safeIdentifier.hasMatch(normalizedRoom) ||
        !_safeIdentifier.hasMatch(normalizedIdentity) ||
        normalizedName.isEmpty ||
        normalizedName.runes.length > 80) {
      _addLog(CallLogLevel.error, '网络诊断参数无效，请检查服务地址、房间和身份。');
      _endAction();
      return false;
    }

    try {
      _addLog(CallLogLevel.info, '正在申请网络诊断用短期令牌…');
      final credentials = await _tokenProvider.issue(
        apiBaseUri: apiBaseUri,
        roomName: normalizedRoom,
        participantIdentity: normalizedIdentity,
        participantName: normalizedName,
      );
      _addLog(CallLogLevel.info, '开始检查 WebSocket、WebRTC 和 TURN relay…');

      final results = await _connectivityCheckRunner(credentials);
      var allPassed = results.length >= 3;
      for (final result in results) {
        final label = switch (result.name) {
          'WebSocketCheck' => 'WebSocket',
          'WebRTCCheck' => 'WebRTC',
          'TURNCheck' => 'TURN',
          _ => result.name,
        };
        final passed = result.status == CheckStatus.success;
        allPassed = allPassed && passed;
        _addLog(
          passed ? CallLogLevel.success : CallLogLevel.error,
          '$label ${passed ? '通过' : '失败'}（${result.status.name}）。',
        );
        for (final detail in result.logs) {
          final level = switch (detail.level) {
            CheckLogLevel.info => CallLogLevel.info,
            CheckLogLevel.warning => CallLogLevel.warning,
            CheckLogLevel.error => CallLogLevel.error,
          };
          _addLog(level, '$label：${detail.message}');
        }
      }

      _addLog(
        allPassed ? CallLogLevel.success : CallLogLevel.error,
        allPassed
            ? '网络诊断全部通过，TURN relay 可用。'
            : '网络诊断未全部通过；TURN 必须显示 success 才算回退能力有效。',
      );
      return allPassed;
    } catch (error) {
      _addLog(CallLogLevel.error, '网络/TURN 诊断失败：${_safeError(error)}');
      return false;
    } finally {
      _endAction();
    }
  }

  @override
  Future<void> leave() async {
    if (!_connected || !_beginAction()) return;
    try {
      _addLog(CallLogLevel.info, '正在离开房间…');
      await _room?.disconnect();
      _addLog(CallLogLevel.success, '已离开房间。');
    } catch (error) {
      _addLog(CallLogLevel.error, '离开房间失败：${_safeError(error)}');
    } finally {
      await _releaseRoom();
      _endAction();
    }
  }

  @override
  Future<void> toggleMicrophone() async {
    if (!_connected || _busy) return;
    _busy = true;
    _notify();
    try {
      await _setMicrophoneEnabled(!_microphoneEnabled);
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  Future<void> toggleCamera() async {
    if (!_connected || _busy) return;
    _busy = true;
    _notify();
    try {
      await _setCameraEnabled(!_cameraEnabled);
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  Future<void> toggleSpeaker() async {
    if (!_connected || _busy) return;
    _busy = true;
    _notify();
    try {
      await _audioSession.toggleSpeaker();
      _addLog(
        CallLogLevel.success,
        _audioSession.speakerPreferred ? '已优先使用扬声器。' : '已优先使用听筒/外接设备。',
      );
    } catch (error) {
      _addLog(CallLogLevel.error, '音频输出切换失败：${_safeError(error)}');
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  Future<void> setCameraSuspended(bool suspended) async {
    if (_cameraSuspended == suspended) return;
    _cameraSuspended = suspended;
    final participant = _room?.localParticipant;
    if (participant == null || !_connected || !_cameraEnabled) {
      _notify();
      return;
    }
    try {
      await participant.setCameraEnabled(!suspended);
      _addLog(
        CallLogLevel.info,
        suspended ? 'App 进入后台，已暂停通话摄像头。' : 'App 回到前台，已恢复通话摄像头。',
      );
    } catch (error) {
      _addLog(CallLogLevel.error, '摄像头生命周期切换失败：${_safeError(error)}');
    }
    _notify();
  }

  @override
  Future<bool> setSystemCallManaged(bool managed, {required bool video}) async {
    if (_systemCallManaged == managed) return true;
    if (managed) {
      _audioActivity.acquire(_systemAudioOwner);
      try {
        await _audioSession.prepare(video: video, externalCallSystem: true);
        _systemCallManaged = true;
        _notify();
        return true;
      } catch (error) {
        _audioActivity.release(_systemAudioOwner);
        _systemCallManaged = false;
        _addLog(CallLogLevel.error, '系统通话音频协调失败：${_safeError(error)}');
        _notify();
        return false;
      }
    }

    var released = true;
    try {
      await _audioSession.release();
    } catch (error) {
      released = false;
      _addLog(CallLogLevel.error, '系统通话音频释放失败：${_safeError(error)}');
    } finally {
      _systemCallManaged = false;
      _audioActivity.release(_systemAudioOwner);
      _notify();
    }
    return released;
  }

  @override
  Future<void> setSystemAudioActive(bool active) async {
    try {
      await _audioSession.handleSystemAudioActivation(active);
    } catch (error) {
      _addLog(CallLogLevel.error, '系统音频激活同步失败：${_safeError(error)}');
    }
    _notify();
  }

  @override
  Future<void> setSystemAudioInterrupted(bool interrupted) async {
    try {
      await _audioSession.handleInterruption(interrupted);
    } catch (error) {
      _addLog(CallLogLevel.error, '系统音频中断同步失败：${_safeError(error)}');
    }
    _notify();
  }

  @override
  Future<void> switchCamera() async {
    if (!_connected || !_cameraEnabled || _cameraSuspended || _busy) return;
    final track = localVideoTrack;
    if (track is! LocalVideoTrack) {
      _addLog(CallLogLevel.warning, '当前没有可切换的本地摄像头轨道。');
      return;
    }

    _busy = true;
    _notify();
    try {
      final nextPosition = _frontCamera
          ? CameraPosition.back
          : CameraPosition.front;
      await track.setCameraPosition(nextPosition);
      _frontCamera = !_frontCamera;
      _addLog(CallLogLevel.success, _frontCamera ? '已切换到前置摄像头。' : '已切换到后置摄像头。');
    } catch (error) {
      _addLog(CallLogLevel.error, '切换摄像头失败：${_safeError(error)}');
    } finally {
      _busy = false;
      _notify();
    }
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    await _releaseRoom(notify: false);
    await _platformSubscription?.cancel();
    _platformSubscription = null;
    if (_systemCallManaged) {
      try {
        await _audioSession.release();
      } catch (_) {}
      _systemCallManaged = false;
    }
    _audioActivity.release(_systemAudioOwner);
    _audioActivity.release(_mediaAudioOwner);
    await _connectionEvents.close();
    _tokenProvider.close();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }

  Future<bool> _connectWithCredentials({
    required CallToken credentials,
    required String roomName,
    required bool enableMicrophone,
    required bool enableCamera,
  }) async {
    final permissions = await _platformGateway.requestMediaPermissions(
      microphone: enableMicrophone,
      camera: enableCamera,
    );
    if (!permissions.allGranted(
      microphone: enableMicrophone,
      camera: enableCamera,
    )) {
      final denied = <String>[
        if (enableMicrophone &&
            permissions.microphone == CallMediaPermission.denied)
          '麦克风',
        if (enableCamera && permissions.camera == CallMediaPermission.denied)
          '摄像头',
      ];
      throw StateError('${denied.join('、')}权限被拒绝，请在系统设置中允许后重试。');
    }

    _audioActivity.acquire(_mediaAudioOwner);
    if (!_systemCallManaged) {
      await _audioSession.prepare(
        video: enableCamera,
        externalCallSystem: false,
      );
    }
    _emitConnection(CallMediaConnectionState.connecting);
    final room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    _room = room;
    _roomName = roomName;
    room.addListener(_handleRoomChange);
    _listener = room.createListener();
    _configureRoomEvents(_listener!);

    await room.prepareConnection(
      credentials.serverUrl.toString(),
      credentials.participantToken,
    );
    _addLog(CallLogLevel.info, '正在连接 ${credentials.serverUrl}…');
    await room.connect(
      credentials.serverUrl.toString(),
      credentials.participantToken,
    );
    _connected = true;
    _emitConnection(CallMediaConnectionState.connected);
    _addLog(CallLogLevel.success, '已加入房间 $roomName。');

    if (enableMicrophone) {
      await _setMicrophoneEnabled(true);
    }
    if (enableCamera) {
      await _setCameraEnabled(true);
    }
    _notify();
    return true;
  }

  Future<void> _setMicrophoneEnabled(bool enabled) async {
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(enabled);
      _microphoneEnabled = enabled;
      _addLog(CallLogLevel.success, enabled ? '麦克风已开启。' : '麦克风已静音。');
    } catch (error) {
      _addLog(CallLogLevel.error, '麦克风操作失败：${_safeError(error)}');
    }
    _notify();
  }

  Future<void> _setCameraEnabled(bool enabled) async {
    try {
      await _room?.localParticipant?.setCameraEnabled(
        enabled && !_cameraSuspended,
      );
      _cameraEnabled = enabled;
      _addLog(CallLogLevel.success, enabled ? '摄像头已开启。' : '摄像头已关闭。');
    } catch (error) {
      _addLog(CallLogLevel.error, '摄像头操作失败：${_safeError(error)}');
    }
    _notify();
  }

  void _configureRoomEvents(EventsListener<RoomEvent> listener) {
    listener
      ..on<RoomReconnectingEvent>((_) {
        _emitConnection(CallMediaConnectionState.reconnecting);
        _addLog(CallLogLevel.warning, '媒体连接中断，正在重连…');
      })
      ..on<RoomAttemptReconnectEvent>((event) {
        _addLog(
          CallLogLevel.info,
          '重连尝试 ${event.attempt}/${event.maxAttemptsRetry}，${event.nextRetryDelaysInMs}ms 后继续。',
        );
      })
      ..on<RoomReconnectedEvent>((_) {
        _connected = true;
        _emitConnection(CallMediaConnectionState.connected);
        _addLog(CallLogLevel.success, '媒体连接已恢复。');
      })
      ..on<RoomDisconnectedEvent>((event) {
        _connected = false;
        _microphoneEnabled = false;
        _cameraEnabled = false;
        _emitConnection(
          CallMediaConnectionState.disconnected,
          unexpected: true,
        );
        _audioActivity.release(_mediaAudioOwner);
        _addLog(
          CallLogLevel.warning,
          '房间连接已断开${event.reason == null ? '' : '：${event.reason}'}。',
        );
      })
      ..on<ParticipantConnectedEvent>((event) {
        _addLog(
          CallLogLevel.success,
          '${_participantLabel(event.participant)} 已加入。',
        );
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _addLog(
          CallLogLevel.warning,
          '${_participantLabel(event.participant)} 已离开。',
        );
      })
      ..on<TrackSubscribedEvent>((event) {
        _addLog(
          CallLogLevel.success,
          '已订阅 ${_participantLabel(event.participant)} 的 ${event.track.kind.name} 轨道。',
        );
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _addLog(
          CallLogLevel.info,
          '已取消订阅 ${_participantLabel(event.participant)} 的轨道。',
        );
      });
  }

  void _handleRoomChange() => _notify();

  void _handlePlatformEvent(CallPlatformEvent event) {
    final route = event.route;
    if (route != null) {
      _audioSession.updateRoute(route);
      _notify();
    }
  }

  void _emitConnection(
    CallMediaConnectionState state, {
    bool unexpected = false,
  }) {
    if (_connectionEvents.isClosed) return;
    _connectionEvents.add(
      CallMediaConnectionEvent(state: state, unexpected: unexpected),
    );
  }

  Future<void> _releaseRoom({bool notify = true}) async {
    final room = _room;
    final listener = _listener;
    _room = null;
    _listener = null;
    _connected = false;
    _microphoneEnabled = false;
    _cameraEnabled = false;
    _cameraSuspended = false;
    _frontCamera = true;
    _roomName = null;

    if (room != null) {
      room.removeListener(_handleRoomChange);
    }
    await listener?.dispose();
    if (room != null) {
      try {
        await room.disconnect();
      } catch (_) {
        // Best-effort cleanup after connection errors.
      }
      await room.dispose();
    }
    _audioActivity.release(_mediaAudioOwner);
    _emitConnection(CallMediaConnectionState.disconnected);
    if (notify) _notify();
  }

  bool _beginAction() {
    if (_closed || _busy) return false;
    _busy = true;
    _notify();
    return true;
  }

  void _endAction() {
    if (_closed) return;
    _busy = false;
    _notify();
  }

  void _addLog(CallLogLevel level, String message) {
    if (_closed) return;
    _logs.add(CallLogEntry(timestamp: _now(), level: level, message: message));
    if (_logs.length > maxLogEntries) {
      _logs.removeRange(0, _logs.length - maxLogEntries);
    }
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  static Future<List<CheckInfo>> _runLiveKitConnectivityChecks(
    CallToken credentials,
  ) async {
    final check = ConnectionCheck(
      credentials.serverUrl.toString(),
      credentials.participantToken,
    );
    try {
      return <CheckInfo>[
        await check.checkWebsocket(),
        await check.checkWebRTC(),
        await check.checkTURN(),
      ];
    } finally {
      await check.dispose();
    }
  }

  static Uri? _parseApiBaseUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.replace(path: '', query: null, fragment: null);
  }

  static String _participantLabel(Participant participant) {
    final name = participant.name.trim();
    return name.isEmpty
        ? participant.identity
        : '$name (${participant.identity})';
  }

  static String _safeError(Object error) {
    final normalized = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 300
        ? normalized
        : '${normalized.substring(0, 297)}…';
  }
}
