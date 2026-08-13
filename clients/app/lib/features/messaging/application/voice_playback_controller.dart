// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../data/voice_playback_engine.dart';
import '../data/voice_playback_source.dart';
import '../data/voice_playback_source_resolver.dart';
import '../domain/messaging_models.dart';
import '../domain/voice_message_selector.dart';

enum VoicePlaybackPhase { idle, starting, playing, paused }

enum VoicePlaybackInterruptReason { manual, leftConversation, callStarted, otherMediaStarted }

final class VoicePlaybackSnapshot {
  const VoicePlaybackSnapshot({required this.phase, this.messageId, this.errorCode});
  const VoicePlaybackSnapshot.idle()
      : phase = VoicePlaybackPhase.idle,
        messageId = null,
        errorCode = null;
  final VoicePlaybackPhase phase;
  final String? messageId;
  final String? errorCode;
}

final class VoicePlaybackFailure {
  const VoicePlaybackFailure({required this.messageId, this.code = 'VOICE_PLAYBACK_FAILED'});
  final String messageId;
  final String code;
}

final class VoicePlaybackController {
  VoicePlaybackController({
    required VoicePlaybackEngine player,
    required VoicePlaybackSourceResolver resolver,
    required VoiceMessageSelector selector,
    required Future<void> Function(String messageId) markHeard,
  }) : _player = player,
       _resolver = resolver,
       _selector = selector,
       _markHeard = markHeard {
    _subscriptions.add(_player.playing.listen(_onPlayingChanged));
    _subscriptions.add(_player.completed.listen((_) => _onCompleted()));
  }

  final VoicePlaybackEngine _player;
  final VoicePlaybackSourceResolver _resolver;
  final VoiceMessageSelector _selector;
  final Future<void> Function(String messageId) _markHeard;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<VoicePlaybackSnapshot> _stateController = StreamController<VoicePlaybackSnapshot>.broadcast();
  final StreamController<VoicePlaybackFailure> _errorController = StreamController<VoicePlaybackFailure>.broadcast();
  final Set<String> _heardMarking = <String>{};

  VoicePlaybackSnapshot _state = const VoicePlaybackSnapshot.idle();
  ChatMessage? _active;
  List<ChatMessage> _queueContext = const [];
  bool _chainEnabled = false;
  int _generation = 0;

  VoicePlaybackSnapshot get state => _state;
  Stream<VoicePlaybackSnapshot> get states => _stateController.stream;
  Stream<VoicePlaybackFailure> get errors => _errorController.stream;

  Future<void> play(ChatMessage message, {required Iterable<ChatMessage> conversationMessages, double rate = 1}) async {
    final mediaId = message.content?.mediaId?.trim() ?? '';
    if (message.type.toUpperCase() != 'VOICE' || mediaId.isEmpty) {
      _fail(message.id);
      return;
    }
    final generation = ++_generation;
    _active = message;
    _queueContext = conversationMessages.toList(growable: false);
    _chainEnabled = _selector.isUnheardRemoteVoice(message);
    _emit(VoicePlaybackSnapshot(phase: VoicePlaybackPhase.starting, messageId: message.id));
    try {
      await _player.stop();
      var source = await _resolver.resolve(message);
      if (generation != _generation) return;
      try {
        await _player.playSource(source, rate: rate);
      } catch (_) {
        if (source is! RemoteVoicePlaybackSource) rethrow;
        source = await _resolver.resolve(message, forceGrantRefresh: true);
        if (generation != _generation) return;
        try {
          await _player.playSource(source, rate: rate);
        } catch (_) {
          final fallback = await _resolver.resolveBytesFallback(message);
          if (generation != _generation) return;
          await _player.playSource(fallback, rate: rate);
        }
      }
    } catch (_) {
      if (generation != _generation) return;
      _chainEnabled = false;
      _active = null;
      _fail(message.id);
    }
  }

  Future<void> pause() async {
    _generation++;
    _chainEnabled = false;
    await _player.pause();
    final active = _active;
    if (active != null) {
      _emit(VoicePlaybackSnapshot(phase: VoicePlaybackPhase.paused, messageId: active.id));
    }
  }

  Future<void> resume({double rate = 1}) async {
    final active = _active;
    if (active == null) return;
    _emit(VoicePlaybackSnapshot(phase: VoicePlaybackPhase.starting, messageId: active.id));
    try {
      await _player.setRate(rate);
      await _player.resume();
    } catch (_) {
      _fail(active.id);
    }
  }

  Future<void> interrupt(VoicePlaybackInterruptReason reason) async {
    _generation++;
    _chainEnabled = false;
    _active = null;
    _queueContext = const [];
    await _player.stop();
    _emit(const VoicePlaybackSnapshot.idle());
  }

  void _onPlayingChanged(bool playing) {
    final active = _active;
    if (!playing || active == null) return;
    _emit(VoicePlaybackSnapshot(phase: VoicePlaybackPhase.playing, messageId: active.id));
    if (!_selector.isUnheardRemoteVoice(active) || !_heardMarking.add(active.id)) return;
    unawaited(_markHeard(active.id).catchError((Object _) {}).whenComplete(() => _heardMarking.remove(active.id)));
  }

  void _onCompleted() {
    final completed = _active;
    if (completed == null) return;
    if (!_chainEnabled) {
      _active = null;
      _emit(const VoicePlaybackSnapshot.idle());
      return;
    }
    final next = _selector.nextUnheardRemoteVoice(completed, _queueContext);
    if (next == null) {
      _chainEnabled = false;
      _active = null;
      _emit(const VoicePlaybackSnapshot.idle());
      return;
    }
    unawaited(play(next, conversationMessages: _queueContext).then((_) {
      final candidates = _queueContext.where((message) =>
          message.conversationId == next.conversationId &&
          message.sequence > next.sequence &&
          _selector.isUnheardRemoteVoice(message));
      return _resolver.prefetch(candidates);
    }));
  }

  void _fail(String messageId) {
    const code = 'VOICE_PLAYBACK_FAILED';
    _generation++;
    _chainEnabled = false;
    _active = null;
    _emit(VoicePlaybackSnapshot(phase: VoicePlaybackPhase.idle, messageId: messageId, errorCode: code));
    if (!_errorController.isClosed) _errorController.add(VoicePlaybackFailure(messageId: messageId));
  }

  void _emit(VoicePlaybackSnapshot next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() async {
    _generation++;
    _chainEnabled = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.stop();
    await _stateController.close();
    await _errorController.close();
  }
}
