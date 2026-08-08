import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'notification_avatar_file.dart';

final class AppNotificationService {
  AppNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    http.Client? httpClient,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _httpClient = httpClient ?? http.Client();

  static final AppNotificationService shared = AppNotificationService();

  static const _channelId = 'dd_messages';
  static const _channelName = 'DD 新消息';
  static const _channelDescription = '好友消息与会话提醒';
  static const MethodChannel _windowChannel = MethodChannel('dd/window');

  final FlutterLocalNotificationsPlugin _plugin;
  final http.Client _httpClient;
  final Map<String, Uint8List?> _avatarMemoryCache = <String, Uint8List?>{};
  bool _initialized = false;
  bool _initializing = false;
  int _nextId = 1000;

  bool get initialized => _initialized;

  Future<void> initialize({bool requestPermission = true}) async {
    if (_initialized || _initializing || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    _initializing = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_dd'),
        windows: WindowsInitializationSettings(
          appName: 'DD',
          appUserModelId: 'OpenIMX.DD.Client',
          guid: 'd4b226ae-97ab-4bb7-9b64-a816e8bb78ac',
        ),
      );
      final initialized = await _plugin.initialize(settings: settings);
      _initialized = initialized ?? false;
      if (!_initialized) return;

      if (requestPermission &&
          defaultTargetPlatform == TargetPlatform.android) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
      }
    } catch (_) {
      // Tests, unsupported embedders and stale locally cached runners may not
      // expose a notification platform implementation. Messaging must survive.
      _initialized = false;
    } finally {
      _initializing = false;
    }
  }

  Future<void> showMessage({
    required String senderName,
    required String preview,
    required String conversationId,
    Uri? origin,
    String? accessToken,
    String? senderUserId,
  }) async {
    final windows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (!_initialized && !windows) return;
    final body = preview.trim().isEmpty ? '你收到了一条新消息' : preview.trim();
    final id = _nextId++ & 0x7FFFFFFF;

    Uint8List? avatarBytes;
    if (origin != null &&
        accessToken != null &&
        accessToken.isNotEmpty &&
        senderUserId != null &&
        senderUserId.isNotEmpty) {
      avatarBytes = await _loadAvatar(
        origin: origin,
        accessToken: accessToken,
        userId: senderUserId,
      );
    }

    try {
      final androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.private,
        largeIcon: avatarBytes == null
            ? null
            : ByteArrayAndroidBitmap(avatarBytes),
        styleInformation: MessagingStyleInformation(
          const Person(name: 'DD'),
          conversationTitle: senderName,
          groupConversation: false,
          messages: <Message>[
            Message(
              body,
              DateTime.now(),
              Person(
                name: senderName,
                icon: avatarBytes == null
                    ? null
                    : ByteArrayAndroidIcon(avatarBytes),
              ),
            ),
          ],
        ),
      );

      WindowsNotificationDetails windowsDetails =
          const WindowsNotificationDetails(
            duration: WindowsNotificationDuration.short,
          );
      Uri? avatarUri;
      if (avatarBytes != null && senderUserId != null) {
        avatarUri = await writeNotificationAvatarFile(
          senderUserId,
          avatarBytes,
        );
        if (avatarUri != null) {
          windowsDetails = WindowsNotificationDetails(
            duration: WindowsNotificationDuration.short,
            images: <WindowsImage>[
              WindowsImage(
                avatarUri,
                altText: '$senderName 的头像',
                placement: WindowsImagePlacement.appLogoOverride,
                crop: WindowsImageCrop.circle,
              ),
            ],
          );
        }
      }

      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await _windowChannel.invokeMethod<void>('showNotification', {
            'title': senderName,
            'body': body,
            'avatarPath': avatarUri?.toFilePath(windows: true) ?? '',
          });
          return;
        } on PlatformException {
          // Fall through to the Windows system notification only if the custom
          // DD popup cannot be created by an older/broken native runner.
        } on MissingPluginException {
          // Widget tests or an older runner: use the plugin fallback below.
        }
      }

      await _plugin.show(
        id: id,
        title: senderName,
        body: body,
        payload: conversationId,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          windows: windowsDetails,
        ),
      );
    } catch (_) {
      // Notification failures must never break realtime message sync.
    }
  }

  Future<Uint8List?> _loadAvatar({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final key = '${origin.origin}|$userId';
    if (_avatarMemoryCache.containsKey(key)) return _avatarMemoryCache[key];
    try {
      final response = await _httpClient.get(
        origin.resolve('/api/v1/avatars/$userId'),
        headers: <String, String>{
          'Accept': 'image/png,image/jpeg,image/webp,*/*',
          'Authorization': 'Bearer $accessToken',
        },
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        _avatarMemoryCache[key] = null;
        return null;
      }
      final bytes = Uint8List.fromList(response.bodyBytes);
      _avatarMemoryCache[key] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

}
