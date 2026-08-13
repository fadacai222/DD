import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:im_client/features/messaging/application/voice_playback_controller.dart';
import 'package:im_client/features/messaging/data/voice_playback_engine.dart';
import 'package:im_client/features/messaging/data/voice_playback_source.dart';
import 'package:im_client/features/messaging/data/voice_playback_source_resolver.dart';
import 'package:im_client/features/messaging/domain/messaging_models.dart';
import 'package:im_client/features/messaging/domain/voice_message_selector.dart';

void main() {
  test('tap publishes starting before source future completes', () async {
    final engine = _FakeEngine();
    final resolver = _FakeResolver()..blockResolve = Completer<void>();
    final heard = <String>{};
    final controller = _controller(engine, resolver, heard);
    final message = _voice('m1', 1);

    final future = controller.play(message, conversationMessages: [message]);
    expect(controller.state.phase, VoicePlaybackPhase.starting);
    expect(engine.sources, isEmpty);

    resolver.blockResolve!.complete();
    await future;
    expect(engine.sources.single, isA<RemoteVoicePlaybackSource>());
    expect(heard, isEmpty);
    await controller.dispose();
  });

  test('heard changes only after real playing event', () async {
    final engine = _FakeEngine();
    final resolver = _FakeResolver();
    final heard = <String>{};
    final controller = _controller(engine, resolver, heard);
    final message = _voice('m1', 1);

    await controller.play(message, conversationMessages: [message]);
    expect(heard, isEmpty);
    engine.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
    expect(heard, {'m1'});
    await controller.dispose();
  });

  test('remote source retries grant then falls back to bounded bytes', () async {
    final engine = _FakeEngine()..failPlayCount = 2;
    final resolver = _FakeResolver();
    final heard = <String>{};
    final controller = _controller(engine, resolver, heard);
    final message = _voice('m1', 1);

    await controller.play(message, conversationMessages: [message]);
    expect(resolver.forceRefreshes, 1);
    expect(resolver.byteFallbacks, 1);
    expect(engine.sources.last, isA<BytesVoicePlaybackSource>());
    expect(controller.state.phase, VoicePlaybackPhase.starting);
    expect(controller.state.errorCode, isNull);
    await controller.dispose();
  });

  test('all playback sources failing returns idle and stable error', () async {
    final engine = _FakeEngine()..failPlayCount = 3;
    final resolver = _FakeResolver();
    final heard = <String>{};
    final controller = _controller(engine, resolver, heard);
    final message = _voice('m1', 1);

    final failures = <VoicePlaybackFailure>[];
    final failureSubscription = controller.errors.listen(failures.add);
    await controller.play(message, conversationMessages: [message]);
    await Future<void>.delayed(Duration.zero);
    expect(resolver.forceRefreshes, 1);
    expect(resolver.byteFallbacks, 1);
    expect(controller.state.phase, VoicePlaybackPhase.idle);
    expect(controller.state.errorCode, 'VOICE_PLAYBACK_FAILED');
    expect(failures.single.code, 'VOICE_PLAYBACK_FAILED');
    expect(heard, isEmpty);
    await failureSubscription.cancel();
    await controller.dispose();
  });

  test('completion chains next unheard remote voice', () async {
    final engine = _FakeEngine();
    final resolver = _FakeResolver();
    final heard = <String>{};
    final controller = _controller(engine, resolver, heard);
    final first = _voice('m1', 1);
    final text = _text('t2', 2);
    final second = _voice('m3', 3);

    await controller.play(first, conversationMessages: [first, text, second]);
    engine.emitPlaying(true);
    await Future<void>.delayed(Duration.zero);
    engine.emitCompleted();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(engine.sources.length, 2);
    expect(controller.state.messageId, 'm3');
    await controller.dispose();
  });

  test('already-heard next voice interrupts the chain', () async {
    final engine = _FakeEngine();
    final resolver = _FakeResolver();
    final heard = <String>{'m2'};
    final controller = _controller(engine, resolver, heard);
    final first = _voice('m1', 1);
    final second = _voice('m2', 2);
    final third = _voice('m3', 3);

    await controller.play(first, conversationMessages: [first, second, third]);
    engine.emitCompleted();
    await Future<void>.delayed(Duration.zero);

    expect(engine.sources.length, 1);
    expect(controller.state.phase, VoicePlaybackPhase.idle);
    await controller.dispose();
  });

  test('pause leave call and other media interrupt auto queue', () async {
    for (final reason in VoicePlaybackInterruptReason.values) {
      final engine = _FakeEngine();
      final resolver = _FakeResolver();
      final heard = <String>{};
      final controller = _controller(engine, resolver, heard);
      final first = _voice('m1', 1);
      final second = _voice('m2', 2);
      await controller.play(first, conversationMessages: [first, second]);

      if (reason == VoicePlaybackInterruptReason.manual) {
        await controller.pause();
      } else {
        await controller.interrupt(reason);
      }
      engine.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(engine.sources.length, 1, reason: reason.name);
      await controller.dispose();
    }
  });

  test('selector excludes own recalled and heard voices', () {
    final selector = VoiceMessageSelector(
      currentUserId: 'me',
      isHeard: (id) => id == 'heard',
    );
    expect(selector.isUnheardRemoteVoice(_voice('ok', 1)), isTrue);
    expect(selector.isUnheardRemoteVoice(_voice('own', 2, sender: 'me')), isFalse);
    expect(selector.isUnheardRemoteVoice(_voice('heard', 3)), isFalse);
    expect(selector.isUnheardRemoteVoice(_voice('gone', 4, recalled: true)), isFalse);
  });
}

VoicePlaybackController _controller(
  _FakeEngine engine,
  _FakeResolver resolver,
  Set<String> heard,
) => VoicePlaybackController(
  player: engine,
  resolver: resolver,
  selector: VoiceMessageSelector(
    currentUserId: 'me',
    isHeard: heard.contains,
  ),
  markHeard: (id) async => heard.add(id),
);

ChatMessage _voice(
  String id,
  int sequence, {
  String sender = 'peer',
  bool recalled = false,
}) => ChatMessage(
  id: id,
  conversationId: 'conversation',
  sequence: sequence,
  senderUserId: sender,
  senderDeviceId: 'device',
  clientMessageId: 'client-$id',
  type: 'VOICE',
  content: TextMessageContent(
    mediaId: 'media-$id',
    mimeType: 'audio/mp4',
    sizeBytes: 1024,
    durationMs: 1200,
  ),
  createdAt: DateTime.utc(2026, 8, 14),
  recalledAt: recalled ? DateTime.utc(2026, 8, 14, 1) : null,
);

ChatMessage _text(String id, int sequence) => ChatMessage(
  id: id,
  conversationId: 'conversation',
  sequence: sequence,
  senderUserId: 'peer',
  senderDeviceId: 'device',
  clientMessageId: 'client-$id',
  type: 'TEXT',
  content: const TextMessageContent(text: 'text'),
  createdAt: DateTime.utc(2026, 8, 14),
);

final class _FakeResolver implements VoicePlaybackSourceResolver {
  Completer<void>? blockResolve;
  int forceRefreshes = 0;
  int byteFallbacks = 0;

  @override
  Future<VoicePlaybackSource> resolve(
    ChatMessage message, {
    bool forceGrantRefresh = false,
  }) async {
    if (forceGrantRefresh) forceRefreshes++;
    await blockResolve?.future;
    return RemoteVoicePlaybackSource(Uri.parse('https://media.example/${message.id}'));
  }

  @override
  Future<VoicePlaybackSource> resolveBytesFallback(ChatMessage message) async {
    byteFallbacks++;
    return BytesVoicePlaybackSource(
      Uint8List.fromList([1, 2, 3]),
      namespace: message.conversationId,
      mediaId: message.content!.mediaId!,
    );
  }

  @override
  Future<void> prefetch(Iterable<ChatMessage> messages) async {}
}

final class _FakeEngine implements VoicePlaybackEngine {
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final List<VoicePlaybackSource> sources = [];
  int failPlayCount = 0;
  bool _isPlaying = false;

  @override
  bool get isPlaying => _isPlaying;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<void> get completed => _completed.stream;
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();

  @override
  Future<void> playSource(VoicePlaybackSource source, {double rate = 1}) async {
    sources.add(source);
    if (failPlayCount > 0) {
      failPlayCount--;
      throw StateError('play failed');
    }
  }

  void emitPlaying(bool value) {
    _isPlaying = value;
    _playing.add(value);
  }

  void emitCompleted() => _completed.add(null);

  @override
  Future<void> pause() async => _isPlaying = false;
  @override
  Future<void> resume() async => _isPlaying = true;
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> stop() async => _isPlaying = false;
}
