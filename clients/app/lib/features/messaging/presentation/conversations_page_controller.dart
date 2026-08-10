import 'package:flutter/foundation.dart';

final class ConversationsPageController extends ChangeNotifier {
  String? _requestedConversationId;
  int _requestSerial = 0;

  String? get requestedConversationId => _requestedConversationId;
  int get requestSerial => _requestSerial;

  void openConversation(String conversationId) {
    final normalized = conversationId.trim();
    if (normalized.isEmpty) return;
    _requestedConversationId = normalized;
    _requestSerial++;
    notifyListeners();
  }
}
