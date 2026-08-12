enum NotificationAuthorizationState {
  unsupported,
  notDetermined,
  granted,
  provisional,
  denied,
}

extension NotificationAuthorizationStateX on NotificationAuthorizationState {
  bool get canRequest => this == NotificationAuthorizationState.notDetermined;

  bool get canDeliver =>
      this == NotificationAuthorizationState.granted ||
      this == NotificationAuthorizationState.provisional;

  bool get requiresSettings => this == NotificationAuthorizationState.denied;
}
