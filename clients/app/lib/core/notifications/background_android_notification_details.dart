import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

AndroidNotificationDetails buildAndroidBackgroundNotificationDetails({
  required String channelId,
  required String channelName,
  required String channelDescription,
  required String smallIcon,
  required String senderName,
  required String body,
  required Uint8List? avatarBytes,
  bool isCall = false,
}) => AndroidNotificationDetails(
  channelId,
  channelName,
  icon: smallIcon,
  channelDescription: channelDescription,
  importance: Importance.max,
  priority: Priority.max,
  category: isCall
      ? AndroidNotificationCategory.call
      : AndroidNotificationCategory.message,
  visibility: NotificationVisibility.private,
  fullScreenIntent: isCall,
  largeIcon: avatarBytes == null ? null : ByteArrayAndroidBitmap(avatarBytes),
  playSound: isCall,
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
          icon: avatarBytes == null ? null : ByteArrayAndroidIcon(avatarBytes),
        ),
      ),
    ],
  ),
);
