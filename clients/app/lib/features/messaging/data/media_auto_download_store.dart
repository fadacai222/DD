import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/security/dd_secure_storage.dart';

final class MediaAutoDownloadPreferences {
  const MediaAutoDownloadPreferences({
    this.images = true,
    this.gifAndStickers = true,
    this.videos = false,
    this.files = false,
  });

  final bool images;
  final bool gifAndStickers;
  final bool videos;
  final bool files;

  MediaAutoDownloadPreferences copyWith({
    bool? images,
    bool? gifAndStickers,
    bool? videos,
    bool? files,
  }) => MediaAutoDownloadPreferences(
    images: images ?? this.images,
    gifAndStickers: gifAndStickers ?? this.gifAndStickers,
    videos: videos ?? this.videos,
    files: files ?? this.files,
  );

  Map<String, Object> toJson() => <String, Object>{
    'images': images,
    'gifAndStickers': gifAndStickers,
    'videos': videos,
    'files': files,
  };

  static MediaAutoDownloadPreferences fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return const MediaAutoDownloadPreferences();
    }
    return MediaAutoDownloadPreferences(
      images: raw['images'] is bool ? raw['images'] as bool : true,
      gifAndStickers: raw['gifAndStickers'] is bool
          ? raw['gifAndStickers'] as bool
          : true,
      videos: raw['videos'] is bool ? raw['videos'] as bool : false,
      files: raw['files'] is bool ? raw['files'] as bool : false,
    );
  }
}

final class MediaAutoDownloadStore extends ChangeNotifier {
  MediaAutoDownloadStore({
    required String userId,
    SecureKeyValueStore? storage,
  }) : _userId = userId.trim(),
       _storage = storage ?? DdSecureStorage.shared;

  static final Map<String, MediaAutoDownloadStore> _shared =
      <String, MediaAutoDownloadStore>{};

  static MediaAutoDownloadStore shared(String userId) {
    final id = userId.trim();
    return _shared.putIfAbsent(id, () => MediaAutoDownloadStore(userId: id));
  }

  final String _userId;
  final SecureKeyValueStore _storage;
  MediaAutoDownloadPreferences _value = const MediaAutoDownloadPreferences();
  bool _loaded = false;

  String get _key => 'dd.media.auto-download.v1.$_userId';
  MediaAutoDownloadPreferences get value => _value;

  Future<MediaAutoDownloadPreferences> load() async {
    if (_loaded) return _value;
    MediaAutoDownloadPreferences next = const MediaAutoDownloadPreferences();
    if (_userId.isNotEmpty) {
      final raw = await _storage.read(_key);
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          next = MediaAutoDownloadPreferences.fromJson(jsonDecode(raw));
        } catch (_) {
          next = const MediaAutoDownloadPreferences();
        }
      }
    }
    _loaded = true;
    _value = next;
    notifyListeners();
    return _value;
  }

  Future<void> save(MediaAutoDownloadPreferences preferences) async {
    if (_userId.isNotEmpty) {
      await _storage.write(_key, jsonEncode(preferences.toJson()));
    }
    _loaded = true;
    _value = preferences;
    notifyListeners();
  }
}
