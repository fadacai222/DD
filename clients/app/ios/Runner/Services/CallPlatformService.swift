import AVFoundation
import CallKit
import Flutter
import Foundation

/// iOS system-call bridge for DD.
///
/// CallKit owns AVAudioSession activation timing. LiveKit remains responsible
/// for the communication category/mode/options and WebRTC media engine.
/// This service only reports system call state, permissions, interruptions and
/// route changes to Flutter; it never creates a second RTC stack.
final class CallPlatformService: NSObject, DDNativeService, FlutterStreamHandler, CXProviderDelegate {
  static let pluginKey = "DDCallPlatformService"
  static let shared = CallPlatformService()

  private let methodChannelName = "org.openimx.client/call_platform"
  private let eventChannelName = "org.openimx.client/call_platform_events"
  private let provider: CXProvider
  private let callController = CXCallController()
  private var eventSink: FlutterEventSink?
  private var recordsByCallID: [String: CallRecord] = [:]
  private var callIDByUUID: [UUID: String] = [:]
  private var pendingActionsByID: [UUID: PendingSystemAction] = [:]
  private var queuedSystemActionEventsByID: [UUID: [String: Any]] = [:]
  private var completedActionIDs: Set<UUID> = []
  private var completedActionOrder: [UUID] = []

  private struct CallRecord {
    let callID: String
    let uuid: UUID
    let incoming: Bool
    var answered: Bool
  }

  private struct PendingSystemAction {
    let action: CXAction
    let callID: String
    let removeRecordOnSuccess: Bool
  }

  override private init() {
    let configuration = CXProviderConfiguration(localizedName: "DD")
    configuration.supportsVideo = true
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: DispatchQueue.main)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: shared.methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler { call, result in
      shared.handleMethod(call, result: result)
    }

    let eventChannel = FlutterEventChannel(
      name: shared.eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(shared)
  }

  private func handleMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "requestMediaPermissions":
      let arguments = call.arguments as? [String: Any] ?? [:]
      requestMediaPermissions(
        microphone: arguments["microphone"] as? Bool ?? false,
        camera: arguments["camera"] as? Bool ?? false,
        result: result
      )
    case "reportIncomingCall":
      guard
        let arguments = call.arguments as? [String: Any],
        let callID = arguments["callId"] as? String,
        let callerName = arguments["callerName"] as? String
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing callId/callerName", details: nil))
        return
      }
      reportIncomingCall(
        callID: callID,
        callerName: callerName,
        video: arguments["video"] as? Bool ?? false,
        result: result
      )
    case "startOutgoingCall":
      guard
        let arguments = call.arguments as? [String: Any],
        let callID = arguments["callId"] as? String,
        let peerName = arguments["peerName"] as? String
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing callId/peerName", details: nil))
        return
      }
      startOutgoingCall(
        callID: callID,
        peerName: peerName,
        video: arguments["video"] as? Bool ?? false,
        result: result
      )
    case "answerCall":
      performCallAction(call, result: result) { CXAnswerCallAction(call: $0) }
    case "endCall":
      performCallAction(call, result: result) { CXEndCallAction(call: $0) }
    case "completeSystemAction":
      guard
        let arguments = call.arguments as? [String: Any],
        let rawActionID = arguments["actionId"] as? String,
        let actionID = UUID(uuidString: rawActionID),
        let success = arguments["success"] as? Bool
      else {
        result(false)
        return
      }
      result(completeSystemAction(actionID: actionID, success: success))
    case "reportConnected":
      guard let callID = callID(from: call) else {
        result(false)
        return
      }
      markConnected(callID: callID)
      result(true)
    case "reportEnded":
      guard let callID = callID(from: call) else {
        result(false)
        return
      }
      reportEnded(callID: callID)
      result(true)
    case "currentAudioRoute":
      result(currentRoutePayload())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func callID(from call: FlutterMethodCall) -> String? {
    (call.arguments as? [String: Any])?["callId"] as? String
  }

  private func requestMediaPermissions(
    microphone: Bool,
    camera: Bool,
    result: @escaping FlutterResult
  ) {
    requestMicrophonePermission(ifNeeded: microphone) { microphoneState in
      self.requestCameraPermission(ifNeeded: camera) { cameraState in
        DispatchQueue.main.async {
          result([
            "microphone": microphoneState,
            "camera": cameraState,
          ])
        }
      }
    }
  }

  private func requestMicrophonePermission(
    ifNeeded needed: Bool,
    completion: @escaping (String) -> Void
  ) {
    guard needed else {
      completion("notRequested")
      return
    }
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      completion("granted")
    case .denied:
      completion("denied")
    case .undetermined:
      session.requestRecordPermission { granted in
        completion(granted ? "granted" : "denied")
      }
    @unknown default:
      completion("unavailable")
    }
  }

  private func requestCameraPermission(
    ifNeeded needed: Bool,
    completion: @escaping (String) -> Void
  ) {
    guard needed else {
      completion("notRequested")
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      completion("granted")
    case .denied, .restricted:
      completion("denied")
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        completion(granted ? "granted" : "denied")
      }
    @unknown default:
      completion("unavailable")
    }
  }

  private func ensureRecord(
    callID: String,
    incoming: Bool
  ) -> CallRecord {
    if let existing = recordsByCallID[callID] {
      return existing
    }
    let record = CallRecord(
      callID: callID,
      uuid: UUID(),
      incoming: incoming,
      answered: false
    )
    recordsByCallID[callID] = record
    callIDByUUID[record.uuid] = callID
    return record
  }

  private func reportIncomingCall(
    callID: String,
    callerName: String,
    video: Bool,
    result: @escaping FlutterResult
  ) {
    let record = ensureRecord(callID: callID, incoming: true)
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.localizedCallerName = callerName
    update.hasVideo = video
    provider.reportNewIncomingCall(with: record.uuid, update: update) { error in
      DispatchQueue.main.async {
        if let error {
          self.removeRecord(callID: callID)
          result(FlutterError(code: "CALLKIT_INCOMING_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
    }
  }

  private func startOutgoingCall(
    callID: String,
    peerName: String,
    video: Bool,
    result: @escaping FlutterResult
  ) {
    let record = ensureRecord(callID: callID, incoming: false)
    let handle = CXHandle(type: .generic, value: peerName)
    let action = CXStartCallAction(call: record.uuid, handle: handle)
    action.isVideo = video
    request(CXTransaction(action: action), result: result)
  }

  private func performCallAction(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult,
    action: (UUID) -> CXAction
  ) {
    guard
      let callID = callID(from: call),
      let record = recordsByCallID[callID]
    else {
      result(false)
      return
    }
    request(CXTransaction(action: action(record.uuid)), result: result)
  }

  private func request(_ transaction: CXTransaction, result: @escaping FlutterResult) {
    callController.request(transaction) { error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "CALLKIT_TRANSACTION_FAILED", message: error.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
    }
  }

  private func beginSystemAction(
    _ action: CXAction,
    type: String,
    callID: String,
    removeRecordOnSuccess: Bool
  ) {
    let actionID = action.uuid
    guard pendingActionsByID[actionID] == nil else {
      action.fail()
      return
    }

    pendingActionsByID[actionID] = PendingSystemAction(
      action: action,
      callID: callID,
      removeRecordOnSuccess: removeRecordOnSuccess
    )
    let payload: [String: Any] = [
      "type": type,
      "callId": callID,
      "actionId": actionID.uuidString,
    ]
    publishSystemAction(payload, actionID: actionID)
  }

  private func completeSystemAction(actionID: UUID, success: Bool) -> Bool {
    if completedActionIDs.contains(actionID) {
      return true
    }
    guard let pending = pendingActionsByID.removeValue(forKey: actionID) else {
      return false
    }
    queuedSystemActionEventsByID.removeValue(forKey: actionID)

    if success {
      pending.action.fulfill()
      if pending.removeRecordOnSuccess {
        removeRecord(callID: pending.callID)
      }
    } else {
      pending.action.fail()
    }
    rememberCompletedActionID(actionID)
    return true
  }

  private func rememberCompletedActionID(_ actionID: UUID) {
    guard completedActionIDs.insert(actionID).inserted else { return }
    completedActionOrder.append(actionID)
    if completedActionOrder.count > 64 {
      let expired = completedActionOrder.removeFirst()
      completedActionIDs.remove(expired)
    }
  }

  private func markConnected(callID: String) {
    guard var record = recordsByCallID[callID] else { return }
    record.answered = true
    recordsByCallID[callID] = record
    if !record.incoming {
      provider.reportOutgoingCall(with: record.uuid, connectedAt: Date())
    }
  }

  private func reportEnded(callID: String) {
    guard let record = recordsByCallID[callID] else { return }
    provider.reportCall(with: record.uuid, endedAt: Date(), reason: .remoteEnded)
    removeRecord(callID: callID)
  }

  private func removeRecord(callID: String) {
    guard let record = recordsByCallID.removeValue(forKey: callID) else { return }
    callIDByUUID.removeValue(forKey: record.uuid)
  }

  func providerDidReset(_ provider: CXProvider) {
    let activeCallIDs = Array(recordsByCallID.keys)
    pendingActionsByID.values.forEach { $0.action.fail() }
    pendingActionsByID.removeAll()
    queuedSystemActionEventsByID.removeAll()
    recordsByCallID.removeAll()
    callIDByUUID.removeAll()
    activeCallIDs.forEach { publish(type: "end", callID: $0) }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let callID = callIDByUUID[action.callUUID] else {
      action.fail()
      return
    }
    beginSystemAction(
      action,
      type: "accept",
      callID: callID,
      removeRecordOnSuccess: false
    )
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    guard
      let callID = callIDByUUID[action.callUUID],
      let record = recordsByCallID[callID]
    else {
      action.fail()
      return
    }
    let eventType = record.answered ? "end" : (record.incoming ? "decline" : "cancel")
    beginSystemAction(
      action,
      type: eventType,
      callID: callID,
      removeRecordOnSuccess: true
    )
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    pendingActionsByID.removeValue(forKey: action.uuid)
    queuedSystemActionEventsByID.removeValue(forKey: action.uuid)
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    publish(type: "audioActivated")
    publishRoute()
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    publish(type: "audioDeactivated")
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    publishRoute()
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard
      let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawValue)
    else { return }
    publish(type: type == .began ? "interruptionBegan" : "interruptionEnded")
  }

  private func publishRoute() {
    var payload = currentRoutePayload()
    payload["type"] = "routeChanged"
    publish(payload)
  }

  private func currentRoutePayload() -> [String: Any] {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    guard let output = outputs.first else {
      return ["routeKind": "other", "routeLabel": "系统音频"]
    }

    let kind: String
    switch output.portType {
    case .builtInReceiver:
      kind = "receiver"
    case .builtInSpeaker:
      kind = "speaker"
    case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
      kind = "bluetooth"
    case .headphones, .headsetMic, .lineOut:
      kind = "headphones"
    case .airPlay:
      kind = "airPlay"
    default:
      kind = "other"
    }
    return [
      "routeKind": kind,
      "routeLabel": output.portName,
    ]
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    let queued = queuedSystemActionEventsByID
    queuedSystemActionEventsByID.removeAll()
    for (actionID, payload) in queued where pendingActionsByID[actionID] != nil {
      events(payload)
    }
    publishRoute()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func publish(type: String, callID: String? = nil) {
    var payload: [String: Any] = ["type": type]
    if let callID {
      payload["callId"] = callID
    }
    publish(payload)
  }

  private func publishSystemAction(_ payload: [String: Any], actionID: UUID) {
    guard let sink = eventSink else {
      queuedSystemActionEventsByID[actionID] = payload
      return
    }
    DispatchQueue.main.async {
      sink(payload)
    }
  }

  private func publish(_ payload: [String: Any]) {
    guard let sink = eventSink else { return }
    DispatchQueue.main.async {
      sink(payload)
    }
  }
}
