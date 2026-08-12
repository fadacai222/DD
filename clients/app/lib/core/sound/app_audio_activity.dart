import 'package:flutter/foundation.dart';

/// Process-wide ownership marker for interactive call audio.
///
/// It does not configure AVAudioSession. It only prevents unrelated DD audio
/// (message cues / voice-message playback) from taking over the session while a
/// LiveKit or CallKit call owns it.
final class AppAudioActivity extends ChangeNotifier {
  final Set<Object> _callOwners = <Object>{};

  static final AppAudioActivity shared = AppAudioActivity();

  bool get callActive => _callOwners.isNotEmpty;
  int get callOwnerCount => _callOwners.length;

  void acquire(Object owner) {
    final wasActive = callActive;
    _callOwners.add(owner);
    if (wasActive != callActive) notifyListeners();
  }

  void release(Object owner) {
    final wasActive = callActive;
    _callOwners.remove(owner);
    if (wasActive != callActive) notifyListeners();
  }
}
