import Flutter
import UIKit
import UserNotifications

/// Small iOS push bridge. AppDelegate/UNUserNotificationCenter hooks are wired
/// by the Platform Foundation owner so this file can stay independently owned.
final class PushNotificationService: NSObject, DDNativeService, FlutterStreamHandler {
  static let pluginKey = "DDPushNotificationService"
  static let shared = PushNotificationService()

  private let methodChannelName = "org.openimx.client/ios_push"
  private let eventChannelName = "org.openimx.client/ios_push_events"
  private let center = UNUserNotificationCenter.current()
  private var eventSink: FlutterEventSink?
  private var pendingEvents: [[String: Any]] = []
  private var apnsToken: String?
  private let lock = NSLock()

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: shared.methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler(shared.handleMethodCall)

    let eventChannel = FlutterEventChannel(
      name: shared.eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(shared)
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorizationState":
      center.getNotificationSettings { settings in
        result(Self.authorizationName(settings.authorizationStatus))
      }
    case "requestAuthorization":
      let arguments = call.arguments as? [String: Any]
      let provisional = arguments?["provisional"] as? Bool ?? false
      requestAuthorization(provisional: provisional, result: result)
    case "openNotificationSettings":
      openNotificationSettings(result: result)
    case "apnsToken":
      lock.lock()
      let token = apnsToken
      lock.unlock()
      result(token)
    case "registerRemoteNotifications":
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
      }
    case "setBadgeCount":
      let arguments = call.arguments as? [String: Any]
      let raw = arguments?["count"] as? Int ?? 0
      setBadgeCount(max(0, raw), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestAuthorization(provisional: Bool, result: @escaping FlutterResult) {
    var options: UNAuthorizationOptions = [.alert, .badge, .sound]
    if provisional {
      options.insert(.provisional)
    }
    center.requestAuthorization(options: options) { _, error in
      if let error = error {
        result(
          FlutterError(
            code: "IOS_NOTIFICATION_PERMISSION_FAILED",
            message: "Unable to request iOS notification authorization.",
            details: error.localizedDescription
          )
        )
        return
      }
      self.center.getNotificationSettings { settings in
        let state = Self.authorizationName(settings.authorizationStatus)
        if settings.authorizationStatus == .authorized ||
          settings.authorizationStatus == .provisional {
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
        result(state)
      }
    }
  }

  private func openNotificationSettings(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let url: URL?
      if #available(iOS 16.0, *) {
        url = URL(string: UIApplication.openNotificationSettingsURLString)
      } else {
        url = URL(string: UIApplication.openSettingsURLString)
      }
      guard let url = url else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
  }

  private func setBadgeCount(_ count: Int, result: @escaping FlutterResult) {
    if #available(iOS 16.0, *) {
      center.setBadgeCount(count) { error in
        if let error = error {
          result(
            FlutterError(
              code: "IOS_BADGE_UPDATE_FAILED",
              message: "Unable to update the iOS app icon badge.",
              details: error.localizedDescription
            )
          )
          return
        }
        result(nil)
      }
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.applicationIconBadgeNumber = count
      result(nil)
    }
  }

  /// AppDelegate hook: forward APNs registration success here.
  func didRegisterForRemoteNotifications(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    guard !token.isEmpty else { return }
    lock.lock()
    apnsToken = token
    lock.unlock()
    publish(["type": "apnsToken", "token": token])
  }

  /// AppDelegate hook: the error is intentionally not forwarded to Flutter or
  /// logs with token material. Dart retries registration on the next resume.
  func didFailToRegisterForRemoteNotifications(_ error: Error) {
    publish(["type": "apnsRegistrationFailed"])
  }

  /// UNUserNotificationCenterDelegate tap hook. The payload is queued until a
  /// valid Flutter session attaches; NativeRouteService provides the same
  /// startup-safe ingress used by other native routes.
  func didReceiveNotificationResponse(_ response: UNNotificationResponse) {
    let payload = Self.normalizedPayload(
      response.notification.request.content.userInfo
    )
    guard !payload.isEmpty else { return }
    publish(["type": "notificationTap", "payload": payload])
    NativeRouteService.shared.publishNotificationRoute("push", metadata: payload)
  }

  /// Foreground remote alerts are intentionally suppressed at the system level.
  /// DD consumes the event through Flutter and its existing in-app/realtime path,
  /// avoiding a system banner plus in-app banner duplicate.
  func foregroundPresentationOptions(
    for notification: UNNotification
  ) -> UNNotificationPresentationOptions {
    let payload = Self.normalizedPayload(notification.request.content.userInfo)
    if !payload.isEmpty {
      publish(["type": "notificationForeground", "payload": payload])
    }
    return []
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    lock.lock()
    eventSink = events
    let queued = pendingEvents
    pendingEvents.removeAll(keepingCapacity: false)
    lock.unlock()
    queued.forEach(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    lock.lock()
    eventSink = nil
    lock.unlock()
    return nil
  }

  private func publish(_ event: [String: Any]) {
    lock.lock()
    if let sink = eventSink {
      lock.unlock()
      DispatchQueue.main.async {
        sink(event)
      }
      return
    }
    pendingEvents.append(event)
    if pendingEvents.count > 16 {
      pendingEvents.removeFirst(pendingEvents.count - 16)
    }
    lock.unlock()
  }

  private static func authorizationName(_ status: UNAuthorizationStatus) -> String {
    if #available(iOS 14.0, *), status == .ephemeral {
      return "GRANTED"
    }
    switch status {
    case .notDetermined:
      return "NOT_DETERMINED"
    case .denied:
      return "DENIED"
    case .authorized:
      return "GRANTED"
    case .provisional:
      return "PROVISIONAL"
    @unknown default:
      return "UNSUPPORTED"
    }
  }

  private static func normalizedPayload(
    _ userInfo: [AnyHashable: Any]
  ) -> [String: Any] {
    var payload: [String: Any] = [:]
    for (key, value) in userInfo {
      let name = String(describing: key)
      if name == "aps" || name == "dd" { continue }
      if let safe = jsonSafe(value) {
        payload[name] = safe
      }
    }
    if let dd = userInfo["dd"] as? [String: Any] {
      for (key, value) in dd {
        if let safe = jsonSafe(value) {
          payload[key] = safe
        }
      }
    }
    return payload
  }

  private static func jsonSafe(_ value: Any) -> Any? {
    if value is String || value is NSNumber || value is NSNull {
      return value
    }
    if let values = value as? [Any] {
      return values.compactMap(jsonSafe)
    }
    if let values = value as? [String: Any] {
      var result: [String: Any] = [:]
      for (key, nested) in values {
        if let safe = jsonSafe(nested) {
          result[key] = safe
        }
      }
      return result
    }
    return nil
  }
}
