import Flutter
import Foundation

/// Native-to-Flutter routing ingress shared by URL/deep-link and future native
/// services. Push/media/call services may publish a route here without growing
/// AppDelegate into a service container.
final class NativeRouteService: NSObject, DDNativeService, FlutterStreamHandler {
  static let pluginKey = "DDNativeRouteService"
  static let shared = NativeRouteService()

  private let channelName = "org.openimx.client/native_routes"
  private var eventSink: FlutterEventSink?
  private var pendingEvents: [[String: Any]] = []
  private let lock = NSLock()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterEventChannel(
      name: shared.channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setStreamHandler(shared)
  }

  func publishURL(_ url: URL, source: String) {
    publish([
      "type": "url",
      "source": source,
      "url": url.absoluteString,
    ])
  }

  /// Reserved ingress for later native notification routing. This foundation
  /// intentionally does not own APNs registration or token lifecycle.
  func publishNotificationRoute(_ route: String, metadata: [String: Any] = [:]) {
    var event = metadata
    event["type"] = "notification"
    event["route"] = route
    publish(event)
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
}
