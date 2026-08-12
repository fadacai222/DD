// LiveKit 2.10.0 marks its CallKit audio-coordination API experimental.
// DD intentionally pins this integration to the locked SDK contract and keeps
// it isolated here so a future LiveKit upgrade has one review point.
// ignore_for_file: experimental_member_use

import 'package:livekit_client/livekit_client.dart';

enum CallAudioManagementMode { automatic, externalCallSystem }

enum CallAudioRouteKind {
  receiver,
  speaker,
  bluetooth,
  headphones,
  airPlay,
  other,
}

final class CallAudioRouteState {
  const CallAudioRouteState({required this.kind, required this.label});

  static const unknown = CallAudioRouteState(
    kind: CallAudioRouteKind.other,
    label: '系统音频',
  );

  final CallAudioRouteKind kind;
  final String label;
}

abstract interface class CallAudioBackend {
  Future<void> setManagementMode(CallAudioManagementMode mode);
  Future<void> setEngineAvailable(bool available);
  Future<void> setSpeakerPreferred(bool preferred);
}

final class LiveKitCallAudioBackend implements CallAudioBackend {
  const LiveKitCallAudioBackend();

  @override
  Future<void> setManagementMode(CallAudioManagementMode mode) {
    return AudioManager.instance.setAudioSessionManagementMode(
      switch (mode) {
        CallAudioManagementMode.automatic =>
          AudioSessionManagementMode.automatic,
        CallAudioManagementMode.externalCallSystem =>
          AudioSessionManagementMode.externalCallSystem,
      },
    );
  }

  @override
  Future<void> setEngineAvailable(bool available) {
    return AudioManager.instance.setEngineAvailability(
      available
          ? AudioEngineAvailability.defaultAvailability
          : AudioEngineAvailability.none,
    );
  }

  @override
  Future<void> setSpeakerPreferred(bool preferred) {
    // force:false is deliberate: a wired/Bluetooth headset must keep priority.
    return AudioManager.instance.setSpeakerOutputPreferred(preferred);
  }
}

/// Owns the LiveKit side of DD call audio-session state.
///
/// With CallKit, CallKit owns AVAudioSession activation/deactivation while
/// LiveKit keeps the communication category/mode/options. Outside CallKit,
/// LiveKit stays in its normal automatic mode.
final class CallAudioSessionController {
  CallAudioSessionController({CallAudioBackend? backend})
    : _backend = backend ?? const LiveKitCallAudioBackend();

  final CallAudioBackend _backend;

  bool _externalCallSystem = false;
  bool _speakerPreferred = true;
  bool _interrupted = false;
  bool _systemAudioActive = false;
  CallAudioRouteState _route = CallAudioRouteState.unknown;

  bool get externalCallSystem => _externalCallSystem;
  bool get speakerPreferred => _speakerPreferred;
  bool get interrupted => _interrupted;
  bool get systemAudioActive => _systemAudioActive;
  CallAudioRouteState get route => _route;

  Future<void> prepare({
    required bool video,
    required bool externalCallSystem,
  }) async {
    _externalCallSystem = externalCallSystem;
    _interrupted = false;
    _systemAudioActive = !externalCallSystem;

    await _backend.setManagementMode(
      externalCallSystem
          ? CallAudioManagementMode.externalCallSystem
          : CallAudioManagementMode.automatic,
    );
    if (externalCallSystem) {
      await _backend.setEngineAvailable(false);
    }
    await setSpeakerPreferred(video);
  }

  Future<void> setSpeakerPreferred(bool preferred) async {
    await _backend.setSpeakerPreferred(preferred);
    _speakerPreferred = preferred;
  }

  Future<void> toggleSpeaker() => setSpeakerPreferred(!_speakerPreferred);

  void updateRoute(CallAudioRouteState route) {
    _route = route;
  }

  Future<void> handleSystemAudioActivation(bool active) async {
    if (!_externalCallSystem) return;
    _systemAudioActive = active;
    if (!active) _interrupted = true;
    await _backend.setEngineAvailable(active);
  }

  Future<void> handleInterruption(bool began) async {
    _interrupted = began;
    if (!_externalCallSystem) return;
    if (began) {
      _systemAudioActive = false;
      await _backend.setEngineAvailable(false);
    }
    // CallKit's next didActivate callback, not interruption-ended, re-enables
    // WebRTC. This avoids racing cellular calls/Siri for AVAudioSession.
  }

  Future<void> release() async {
    if (_externalCallSystem) {
      await _backend.setEngineAvailable(true);
      await _backend.setManagementMode(CallAudioManagementMode.automatic);
    }
    _externalCallSystem = false;
    _interrupted = false;
    _systemAudioActive = true;
    _route = CallAudioRouteState.unknown;
  }
}
