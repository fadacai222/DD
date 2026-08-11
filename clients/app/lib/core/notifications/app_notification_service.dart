import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'notification_avatar_file.dart';
import 'notification_avatar_url_policy.dart';

final class AppNotificationService {
  AppNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    http.Client? httpClient,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _httpClient = httpClient ?? http.Client();

  static final AppNotificationService shared = AppNotificationService();

  static const String androidSmallIcon = 'ic_stat_dd';
  // Android notification-channel importance is immutable after first creation.
  // v1 was created by some test builds with non-heads-up settings, so keep a
  // versioned id and migrate users to a fresh high-importance channel.
  static const String androidChannelId = 'dd_messages_v2';
  static const _channelName = 'DD 新消息';
  static const _channelDescription = '消息与会话提醒';
  static const MethodChannel _windowChannel = MethodChannel('dd/window');

  final FlutterLocalNotificationsPlugin _plugin;
  final http.Client _httpClient;
  final Map<String, Uint8List?> _avatarMemoryCache = <String, Uint8List?>{};
  final StreamController<Map<String, dynamic>> _notificationOpenController =
      StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic>? _pendingLaunchData;
  bool _initialized = false;
  bool _initializing = false;
  int _nextId = 1000;

  bool get initialized => _initialized;

  Stream<Map<String, dynamic>> get notificationOpens =>
      _notificationOpenController.stream;

  Map<String, dynamic>? takePendingLaunchData() {
    final data = _pendingLaunchData;
    _pendingLaunchData = null;
    return data;
  }

  Future<void> initialize({bool requestPermission = true}) async {
    if (_initialized || _initializing || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }

    _initializing = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings(androidSmallIcon),
        windows: WindowsInitializationSettings(
          appName: 'DD',
          appUserModelId: 'OpenIMX.DD.Client',
          guid: 'd4b226ae-97ab-4bb7-9b64-a816e8bb78ac',
        ),
      );
      final initialized = await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleNotificationResponse,
      );
      _initialized = initialized ?? false;
      if (!_initialized) return;

      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        _pendingLaunchData = _decodeNotificationPayload(
          launchDetails?.notificationResponse?.payload,
        );
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            androidChannelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.max,
            playSound: false,
            enableVibration: true,
            showBadge: true,
          ),
        );
        if (requestPermission) {
          await android?.requestNotificationsPermission();
        }
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
    Uri? avatarUrl,
    Map<String, dynamic>? notificationData,
  }) async {
    final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    if (!_initialized && !windows) return;
    final body = preview.trim().isEmpty ? '你收到了一条新消息' : preview.trim();
    final id = _nextId++ & 0x7FFFFFFF;

    Uint8List? avatarBytes;
    if (avatarUrl != null) {
      avatarBytes = await _loadAvatarUrl(avatarUrl);
    }
    if (avatarBytes == null &&
        origin != null &&
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
        androidChannelId,
        _channelName,
        icon: androidSmallIcon,
        channelDescription: _channelDescription,
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.private,
        largeIcon: avatarBytes == null
            ? null
            : ByteArrayAndroidBitmap(avatarBytes),
        playSound: false,
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

      WindowsNotificationDetails windowsDetails = WindowsNotificationDetails(
        duration: WindowsNotificationDuration.short,
        audio: WindowsNotificationAudio.silent(),
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
            audio: WindowsNotificationAudio.silent(),
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
        payload: notificationData == null
            ? conversationId
            : jsonEncode(notificationData),
        notificationDetails: NotificationDetails(
          android: androidDetails,
          windows: windowsDetails,
        ),
      );
    } catch (_) {
      // Notification failures must never break realtime message sync.
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final data = _decodeNotificationPayload(response.payload);
    if (data == null) return;
    _notificationOpenController.add(data);
  }

  Map<String, dynamic>? _decodeNotificationPayload(String? payload) {
    final raw = payload?.trim() ?? '';
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Legacy local notifications stored only the conversation id.
    }
    return <String, dynamic>{'conversationId': raw};
  }

  Future<Uint8List?> _loadAvatarUrl(Uri avatarUrl) async {
    if (!isAllowedNotificationAvatarUrl(avatarUrl)) return null;
    final key = 'push:${avatarUrl.toString()}';
    if (_avatarMemoryCache.containsKey(key)) return _avatarMemoryCache[key];
    try {
      final response = await _httpClient
          .get(avatarUrl, headers: const <String, String>{'Accept': 'image/*'})
          .timeout(const Duration(seconds: 3));
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > 2 * 1024 * 1024 ||
          !contentType.startsWith('image/')) {
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

  Future<Uint8List?> _loadAvatar({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    final key = '${origin.origin}|$userId';
    if (_avatarMemoryCache.containsKey(key)) return _avatarMemoryCache[key];
    try {
      final response = await _httpClient
          .get(
            origin.resolve('/api/v1/avatars/$userId'),
            headers: <String, String>{
              'Accept': 'image/png,image/jpeg,image/webp,*/*',
              'Authorization': 'Bearer $accessToken',
            },
          )
          .timeout(const Duration(seconds: 3));
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
