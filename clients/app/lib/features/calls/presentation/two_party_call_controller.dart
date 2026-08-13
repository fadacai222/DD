import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:realtime_poc/realtime_poc.dart';

import '../../../core/logging/client_log.dart';
import '../data/call_platform_service.dart';
import '../data/call_signaling_client.dart';
import '../data/http_call_session_api.dart';
import '../domain/call_media_gateway.dart';
import '../domain/call_session.dart';

final class TwoPartyCallController extends ChangeNotifier {
  factory TwoPartyCallController(
    CallMediaGateway media, {
    CallSessionApi? api,
    CallSignalingFactory? signalingFactory,
    Future<String?> Function()? accessTokenProvider,
    CallPlatformGateway? platformGateway,
    List<Duration> mediaRecoveryDelays = const <Duration>[
      Duration.zero,
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
    ],
  }) => TwoPartyCallController._(
    media,
    api ?? HttpCallSessionApi(accessTokenProvider: accessTokenProvider),
    signalingFactory,
    accessTokenProvider,
    platformGateway ?? CallPlatformService.shared,
    mediaRecoveryDelays,
  );

  TwoPartyCallController._(
    this._media,
    this._api,
    this._signalingFactory,
    this._accessTokenProvider,
    this._platformGateway,
    this._mediaRecoveryDelays,
  ) {
    _platformEventSubscription = _platformGateway.events.listen(
      _handlePlatformEvent,
    );
    _mediaEventSubscription = _media.connectionEvents.listen(
      _handleMediaConnectionEvent,
    );
  }

  static final RegExp _safeIdentifier = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );

  final CallMediaGateway _media;
  final CallSessionApi _api;
  final CallSignalingFactory? _signalingFactory;
  final Future<String?> Function()? _accessTokenProvider;
  final CallPlatformGateway _platformGateway;
  final List<Duration> _mediaRecoveryDelays;

  CallSignalingClient? _signaling;
  StreamSubscription<RealtimeEvent>? _eventSubscription;
  StreamSubscription<RealtimeConnectionState>? _stateSubscription;
  StreamSubscription<Object>? _errorSubscription;
  StreamSubscription<CallPlatformEvent>? _platformEventSubscription;
  StreamSubscription<CallMediaConnectionEvent>? _mediaEventSubscription;
  Timer? _mediaRecoveryTimer;

  Uri? _apiBaseUri;
  String _identity = '';
  String _displayName = '';
  CallSession? _currentCall;
  RealtimeConnectionState _signalingState =
      RealtimeConnectionState.disconnected;
  bool _busy = false;
  bool _mediaJoinInProgress = false;
  bool _initialRecoveryComplete = false;
  bool _platformAvailable = false;
  bool _systemCallManaged = false;
  bool _mediaRecoveryInProgress = false;
  int _mediaRecoveryAttempt = 0;
  bool _closed = false;
  String? _errorMessage;

  CallSession? get currentCall => _currentCall;
  RealtimeConnectionState get signalingState => _signalingState;
  bool get busy => _busy;
  bool get mediaJoinInProgress => _mediaJoinInProgress;
  String? get errorMessage => _errorMessage;
  String get identity => _identity;
  String get displayName => _displayName;
  bool get signalingConnected =>
      _signalingState == RealtimeConnectionState.connected;
  bool get isIncoming => _currentCall?.isIncomingFor(_identity) ?? false;
  bool get isOutgoing => _currentCall?.isOutgoingFor(_identity) ?? false;
  bool get isInCall =>
      _currentCall?.status == CallSessionStatus.accepted && _media.connected;
  bool get systemCallManaged => _systemCallManaged;

  String get peerIdentity {
    final call = _currentCall;
    if (call == null || _identity.isEmpty) return '';
    return call.peerIdentityFor(_identity);
  }

  Future<bool> start({
    required String apiBaseUrl,
    required String participantIdentity,
    required String participantName,
  }) async {
    if (_closed || _busy) return false;

    final apiBaseUri = _parseApiBaseUri(apiBaseUrl);
    final identity = participantIdentity.trim();
    final displayName = participantName.trim();
    if (apiBaseUri == null ||
        !_safeIdentifier.hasMatch(identity) ||
        displayName.isEmpty ||
        displayName.runes.length > 80) {
      _setError('参数无效：服务地址需为 http/https，身份只能用字母、数字、点、下划线或短横线。');
      return false;
    }

    _busy = true;
    _errorMessage = null;
    _notify();
    try {
      await _disposeSignaling();
      _platformAvailable = await _platformGateway.isAvailable();
      _apiBaseUri = apiBaseUri;
      _identity = identity;
      _displayName = displayName;

      final accessToken = _accessTokenProvider == null
          ? null
          : (await _accessTokenProvider())?.trim();
      if (_accessTokenProvider != null &&
          (accessToken == null || accessToken.isEmpty)) {
        throw const CallApiException(
          code: 'AUTH_REQUIRED',
          message: '当前登录状态已失效，无法连接通话服务。',
        );
      }
      final signalingFactory = _signalingFactory;
      final signaling = signalingFactory != null
          ? signalingFactory(
              apiBaseUri: apiBaseUri,
              participantIdentity: identity,
            )
          : RealtimeCallSignalingClient(
              apiBaseUri: apiBaseUri,
              participantIdentity: identity,
              accessToken: accessToken,
            );
      _signaling = signaling;
      _eventSubscription = signaling.events.listen(_handleRealtimeEvent);
      _stateSubscription = signaling.states.listen((state) {
        unawaited(ClientLog.info('Call signaling state: ${state.name}'));
        final wasConnected =
            _signalingState == RealtimeConnectionState.connected;
        _signalingState = state;
        if (state == RealtimeConnectionState.connected &&
            !wasConnected &&
            _initialRecoveryComplete) {
          unawaited(_recoverActiveCall());
        }
        _notify();
      });
      _errorSubscription = signaling.errors.listen((error) {
        _setError('实时信令异常：${_safeError(error)}', preserveCall: true);
      });

      await signaling.connect();
      await _recoverActiveCall();
      _initialRecoveryComplete = true;
      return true;
    } catch (error) {
      _setError('连接通话服务失败：${_safeError(error)}', preserveCall: true);
      await _disposeSignaling();
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> placeCall({
    required String calleeIdentity,
    required CallKind kind,
  }) async {
    final apiBaseUri = _apiBaseUri;
    final target = calleeIdentity.trim();
    if (_closed ||
        _busy ||
        apiBaseUri == null ||
        !signalingConnected ||
        _currentCall?.isActive == true) {
      return;
    }
    if (target.isEmpty) {
      _setError('请输入对方身份。');
      return;
    }
    if (target == _identity) {
      _setError('不能呼叫自己。');
      return;
    }
    if (!_safeIdentifier.hasMatch(target)) {
      _setError('对方身份格式无效。');
      return;
    }

    await _runAction(() async {
      final call = await _api.createCall(
        apiBaseUri: apiBaseUri,
        callerIdentity: _identity,
        callerName: _displayName,
        calleeIdentity: target,
        kind: kind,
      );
      await _applyCall(call);
    });
  }

  Future<void> accept() async {
    final call = _currentCall;
    if (_systemCallManaged &&
        call != null &&
        call.status == CallSessionStatus.ringing &&
        call.isIncomingFor(_identity) &&
        await _platformGateway.answerCall(call.id)) {
      return;
    }
    await _applyServerAction('accept');
  }

  Future<void> reject() async {
    final call = _currentCall;
    if (_systemCallManaged &&
        call != null &&
        call.status == CallSessionStatus.ringing &&
        await _platformGateway.endCall(call.id)) {
      return;
    }
    await _applyServerAction('reject');
  }

  Future<void> hangup() async {
    final call = _currentCall;
    if (_systemCallManaged &&
        call != null &&
        call.isActive &&
        await _platformGateway.endCall(call.id)) {
      return;
    }
    await _applyServerAction('hangup');
  }

  void clearEndedCall() {
    final call = _currentCall;
    if (call == null || call.isActive) return;
    _currentCall = null;
    _errorMessage = null;
    _notify();
  }

  Future<bool> _applyServerAction(
    String action, {
    bool reportSystemEnd = true,
    bool releaseSystemCallManagement = true,
  }) async {
    final apiBaseUri = _apiBaseUri;
    final call = _currentCall;
    if (_closed || _busy || apiBaseUri == null || call == null) return false;

    var succeeded = false;
    await _runAction(() async {
      final updated = await _api.applyAction(
        apiBaseUri: apiBaseUri,
        callId: call.id,
        participantIdentity: _identity,
        action: action,
      );
      await _applyCall(
        updated,
        reportSystemEnd: reportSystemEnd,
        releaseSystemCallManagement: releaseSystemCallManagement,
      );
      succeeded = true;
    });
    return succeeded;
  }

  Future<void> _runAction(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    _notify();
    try {
      await action();
    } on CallApiException catch (error) {
      if (error.code == 'INVALID_CALL_STATE') {
        await _recoverActiveCall(clearWhenMissing: true);
        if (_currentCall?.isActive == true) {
          _setError('通话状态已自动同步，请再试一次。', preserveCall: true);
        }
      } else {
        _setError(_friendlyApiError(error), preserveCall: true);
      }
    } catch (error) {
      _setError('通话操作失败：${_safeError(error)}', preserveCall: true);
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    if (event.type != 'call.incoming' && event.type != 'call.updated') return;
    unawaited(
      ClientLog.info(
        'Call signaling event received: type=${event.type}, eventId=${event.eventId}',
      ),
    );
    try {
      final call = CallSession.fromJson(event.payload);
      final deliveryMs = DateTime.now()
          .toUtc()
          .difference(call.createdAt.toUtc())
          .inMilliseconds
          .clamp(0, 24 * 60 * 60 * 1000);
      unawaited(
        ClientLog.info(
          'Call event parsed: callId=${call.id}, status=${call.status.name}, kind=${call.kind.name}, ageMs=$deliveryMs',
        ),
      );
      if (call.callerIdentity != _identity &&
          call.calleeIdentity != _identity) {
        return;
      }
      unawaited(_applyCall(call));
    } catch (error) {
      _setError('收到无效通话事件：${_safeError(error)}', preserveCall: true);
    }
  }

  Future<void> _recoverActiveCall({bool clearWhenMissing = false}) async {
    final apiBaseUri = _apiBaseUri;
    if (_closed || apiBaseUri == null || _identity.isEmpty) return;

    try {
      final active = await _api.fetchActiveCall(
        apiBaseUri: apiBaseUri,
        participantIdentity: _identity,
      );
      if (active != null) {
        await _applyCall(active);
      } else if (clearWhenMissing) {
        final stale = _currentCall;
        if (_media.connected) await _media.leave();
        if (stale != null && stale.isActive) {
          _currentCall = CallSession(
            id: stale.id,
            roomName: stale.roomName,
            callerIdentity: stale.callerIdentity,
            callerName: stale.callerName,
            calleeIdentity: stale.calleeIdentity,
            kind: stale.kind,
            status: CallSessionStatus.ended,
            createdAt: stale.createdAt,
            acceptedAt: stale.acceptedAt,
            endedAt: DateTime.now().toUtc(),
            endReason: 'state_changed',
          );
        }
        _errorMessage = null;
        _notify();
      }
    } catch (error) {
      _setError('恢复通话状态失败：${_safeError(error)}', preserveCall: true);
    }
  }

  Future<void> _applyCall(
    CallSession call, {
    bool reportSystemEnd = true,
    bool releaseSystemCallManagement = true,
  }) async {
    if (_closed) return;
    final previous = _currentCall;
    if (previous != null && previous.id != call.id && previous.isActive) {
      return;
    }

    _currentCall = call;
    _errorMessage = null;
    _notify();

    await _syncSystemCall(previous, call);

    if (call.status == CallSessionStatus.accepted) {
      await _ensureMediaConnected(call);
      return;
    }
    if (!call.isActive) {
      _cancelMediaRecovery();
      if (_media.connected) {
        await _media.leave();
      }
      if (_systemCallManaged) {
        if (reportSystemEnd) {
          await _platformGateway.reportEnded(call.id);
        }
        if (releaseSystemCallManagement) {
          await _media.setSystemCallManaged(
            false,
            video: call.kind == CallKind.video,
          );
          _systemCallManaged = false;
        }
      }
      _notify();
    }
  }

  Future<void> _syncSystemCall(
    CallSession? previous,
    CallSession call,
  ) async {
    if (!_platformAvailable) return;

    if (call.status == CallSessionStatus.ringing &&
        (previous == null || previous.id != call.id)) {
      // Establish LiveKit's external-call audio gate before asking CallKit to
      // start/present the system call. CXProvider may invoke didActivate while
      // the CallKit transaction is still completing; preparing first prevents
      // that activation event from being lost and then overwritten by a late
      // engineAvailability=none.
      final managed = await _media.setSystemCallManaged(
        true,
        video: call.kind == CallKind.video,
      );
      if (!managed) return;

      final presented = call.isIncomingFor(_identity)
          ? await _platformGateway.reportIncomingCall(
              callId: call.id,
              callerName: call.callerName,
              video: call.kind == CallKind.video,
            )
          : await _platformGateway.startOutgoingCall(
              callId: call.id,
              peerName: call.peerIdentityFor(_identity),
              video: call.kind == CallKind.video,
            );
      if (presented) {
        _systemCallManaged = true;
      } else {
        await _media.setSystemCallManaged(
          false,
          video: call.kind == CallKind.video,
        );
      }
      _notify();
      return;
    }

    if (_systemCallManaged &&
        call.status == CallSessionStatus.accepted &&
        previous?.status != CallSessionStatus.accepted) {
      await _platformGateway.reportConnected(call.id);
    }
  }

  Future<void> _ensureMediaConnected(CallSession call) async {
    final apiBaseUri = _apiBaseUri;
    if (_closed ||
        apiBaseUri == null ||
        _media.connected ||
        _mediaJoinInProgress ||
        _currentCall?.id != call.id) {
      return;
    }

    _mediaJoinInProgress = true;
    _notify();
    try {
      final token = await _api.issueToken(
        apiBaseUri: apiBaseUri,
        callId: call.id,
        participantIdentity: _identity,
        participantName: _displayName,
      );
      final joined = await _media.joinWithCredentials(
        credentials: token,
        roomName: call.roomName,
        enableMicrophone: true,
        enableCamera: call.kind == CallKind.video,
      );
      if (!joined) {
        throw StateError(_media.lastError ?? '媒体房间连接失败');
      }
    } catch (error) {
      _setError('无法进入音视频房间：${_safeError(error)}', preserveCall: true);
      _scheduleMediaRecovery();
    } finally {
      _mediaJoinInProgress = false;
      _notify();
    }
  }

  void _handlePlatformEvent(CallPlatformEvent event) {
    if (_closed) return;
    if (_isSystemActionEvent(event.type)) {
      unawaited(_handleSystemCallAction(event));
      return;
    }

    final call = _currentCall;
    final eventCallId = event.callId;
    if (eventCallId != null && call?.id != eventCallId) return;

    switch (event.type) {
      case CallPlatformEventType.audioActivated:
        unawaited(_media.setSystemAudioActive(true));
      case CallPlatformEventType.audioDeactivated:
        unawaited(_media.setSystemAudioActive(false));
      case CallPlatformEventType.interruptionBegan:
        unawaited(_media.setSystemAudioInterrupted(true));
      case CallPlatformEventType.interruptionEnded:
        unawaited(_media.setSystemAudioInterrupted(false));
      case CallPlatformEventType.routeChanged:
      case CallPlatformEventType.accept:
      case CallPlatformEventType.decline:
      case CallPlatformEventType.cancel:
      case CallPlatformEventType.end:
      case CallPlatformEventType.unknown:
        break;
    }
  }

  bool _isSystemActionEvent(CallPlatformEventType type) =>
      type == CallPlatformEventType.accept ||
      type == CallPlatformEventType.decline ||
      type == CallPlatformEventType.cancel ||
      type == CallPlatformEventType.end;

  Future<void> _handleSystemCallAction(CallPlatformEvent event) async {
    final call = _currentCall;
    final actionId = event.actionId?.trim();

    if (actionId == null || actionId.isEmpty) {
      // Provider reset and legacy native bridges do not carry a CXAction id.
      // They cannot participate in the two-phase acknowledgement contract.
      if (event.type == CallPlatformEventType.end && call?.isActive == true) {
        await _applyServerAction('hangup');
      }
      return;
    }

    if (call == null || event.callId != call.id) {
      await _platformGateway.completeSystemAction(
        actionId: actionId,
        success: false,
      );
      return;
    }

    final serverAction = switch (event.type) {
      CallPlatformEventType.accept
          when call.status == CallSessionStatus.ringing &&
              call.isIncomingFor(_identity) =>
        'accept',
      CallPlatformEventType.decline
          when call.status == CallSessionStatus.ringing &&
              call.isIncomingFor(_identity) =>
        'reject',
      CallPlatformEventType.cancel
          when call.status == CallSessionStatus.ringing &&
              call.isOutgoingFor(_identity) =>
        'hangup',
      CallPlatformEventType.end
          when call.status == CallSessionStatus.accepted =>
        'hangup',
      _ => null,
    };

    if (serverAction == null) {
      await _platformGateway.completeSystemAction(
        actionId: actionId,
        success: false,
      );
      return;
    }

    final endsCall = serverAction != 'accept';
    final succeeded = await _applyServerAction(
      serverAction,
      reportSystemEnd: false,
      releaseSystemCallManagement: !endsCall,
    );
    final nativeCompleted = await _platformGateway.completeSystemAction(
      actionId: actionId,
      success: succeeded,
    );

    if (succeeded && endsCall && _systemCallManaged) {
      if (!nativeCompleted) {
        // CallKit may have timed the CXEndCallAction out while the DD server
        // request was in flight. The server is now authoritative-ended, so
        // explicitly converge the retained native record before releasing
        // externalCallSystem audio ownership.
        await _platformGateway.reportEnded(call.id);
      }
      await _media.setSystemCallManaged(
        false,
        video: call.kind == CallKind.video,
      );
      _systemCallManaged = false;
      _notify();
    }
  }

  void _handleMediaConnectionEvent(CallMediaConnectionEvent event) {
    if (_closed) return;
    if (event.state == CallMediaConnectionState.connected) {
      _cancelMediaRecovery();
      if (_errorMessage?.startsWith('媒体连接') == true ||
          _errorMessage?.startsWith('无法进入音视频房间') == true) {
        _errorMessage = null;
        _notify();
      }
      return;
    }
    if (event.state == CallMediaConnectionState.disconnected &&
        event.unexpected &&
        _currentCall?.status == CallSessionStatus.accepted) {
      _setError('媒体连接中断，正在自动恢复…', preserveCall: true);
      _scheduleMediaRecovery();
    }
  }

  void _scheduleMediaRecovery() {
    if (_closed ||
        _media.connected ||
        _mediaRecoveryInProgress ||
        _mediaRecoveryTimer != null ||
        _currentCall?.status != CallSessionStatus.accepted) {
      return;
    }
    if (_mediaRecoveryAttempt >= _mediaRecoveryDelays.length) {
      _setError('媒体连接暂时无法恢复，请保持页面打开或手动挂断后重试。', preserveCall: true);
      return;
    }
    final delay = _mediaRecoveryDelays[_mediaRecoveryAttempt];
    _mediaRecoveryAttempt++;
    _mediaRecoveryTimer = Timer(delay, () {
      _mediaRecoveryTimer = null;
      unawaited(_recoverMediaConnection());
    });
  }

  Future<void> _recoverMediaConnection() async {
    final call = _currentCall;
    if (_closed || call?.status != CallSessionStatus.accepted || _media.connected) {
      return;
    }
    _mediaRecoveryInProgress = true;
    try {
      await _ensureMediaConnected(call!);
      if (!_media.connected) _scheduleMediaRecovery();
    } finally {
      _mediaRecoveryInProgress = false;
      if (!_media.connected) _scheduleMediaRecovery();
    }
  }

  void _cancelMediaRecovery() {
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = null;
    _mediaRecoveryAttempt = 0;
  }

  void updateAccessToken(String accessToken) {
    final normalized = accessToken.trim();
    if (normalized.isEmpty) return;
    final signaling = _signaling;
    if (signaling is RealtimeCallSignalingClient) {
      unawaited(signaling.updateAccessToken(normalized));
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _cancelMediaRecovery();
    await _disposeSignaling();
    await _platformEventSubscription?.cancel();
    await _mediaEventSubscription?.cancel();
    _platformEventSubscription = null;
    _mediaEventSubscription = null;
    if (_media.connected) {
      await _media.leave();
    }
    if (_systemCallManaged) {
      final call = _currentCall;
      if (call != null) await _platformGateway.reportEnded(call.id);
      await _media.setSystemCallManaged(
        false,
        video: call?.kind == CallKind.video,
      );
      _systemCallManaged = false;
    }
    _api.close();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }

  Future<void> _disposeSignaling() async {
    // Stop the underlying client first: its dispose path synchronously cancels
    // connect/reconnect/heartbeat timers before the first await. This matters when
    // logging out while a websocket handshake is still pending.
    final signaling = _signaling;
    _signaling = null;
    final signalingDispose = signaling?.dispose();

    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();
    await _errorSubscription?.cancel();
    _eventSubscription = null;
    _stateSubscription = null;
    _errorSubscription = null;
    await signalingDispose;
    _signalingState = RealtimeConnectionState.disconnected;
    _initialRecoveryComplete = false;
  }

  void _setError(String message, {bool preserveCall = false}) {
    _errorMessage = message;
    unawaited(ClientLog.error('Call: $message'));
    if (!preserveCall) _currentCall = null;
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
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

  static String _friendlyApiError(CallApiException error) {
    return switch (error.code) {
      'CALL_BUSY' => '对方或你正在通话中。',
      'CALL_NOT_FOUND' => '该通话已经不存在。',
      'INVALID_CALL_STATE' => '通话状态已变化，正在自动同步。',
      'CALL_CONTACT_REQUIRED' => '只能给联系人发起语音/视频通话，请先添加对方为联系人。',
      'CALL_FORBIDDEN' => '当前设备无权操作这通电话，请同步最新通话状态后重试。',
      _ => '通话服务错误：${error.message}',
    };
  }

  static String _safeError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 240 ? text : '${text.substring(0, 237)}…';
  }
}
