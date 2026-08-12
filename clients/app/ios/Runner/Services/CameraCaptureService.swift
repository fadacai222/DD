import AVFoundation
import Flutter
import Foundation
import UIKit

/// System-camera implementation for `dd/camera_capture`.
///
/// DD intentionally uses UIImagePickerController here instead of building a
/// second camera UI. A captured still is written to an app-owned cache file and
/// Dart receives only that path.
final class CameraCaptureService: NSObject, DDNativeService {
  static let pluginKey = "DDCameraCaptureService"
  private static let shared = CameraCaptureService()
  private static let channelName = "dd/camera_capture"

  private var pendingResult: FlutterResult?
  private weak var activePicker: UIImagePickerController?
  private var backgroundObserver: NSObjectProtocol?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak shared] call, result in
      shared?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capturePhoto":
      capturePhoto(result: result)
    case "openAppSettings":
      openAppSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func capturePhoto(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "CAMERA_BUSY",
          message: "相机正在使用中。",
          details: nil
        )
      )
      return
    }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(
        FlutterError(
          code: "CAMERA_UNAVAILABLE",
          message: "当前 iPhone/iPad 没有可用相机。",
          details: nil
        )
      )
      return
    }

    pendingResult = result
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      presentCamera()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.presentCamera()
          } else {
            self.failPermission()
          }
        }
      }
    case .denied, .restricted:
      failPermission()
    @unknown default:
      fail(
        code: "CAMERA_PERMISSION_UNKNOWN",
        message: "iOS 返回了未知的相机权限状态。",
        details: nil
      )
    }
  }

  private func presentCamera() {
    guard let presenter = topViewController() else {
      fail(
        code: "CAMERA_UNAVAILABLE",
        message: "当前没有可显示系统相机的 iOS 页面。",
        details: nil
      )
      return
    }

    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = self
    picker.modalPresentationStyle = .fullScreen
    activePicker = picker
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.interruptCapture()
    }
    presenter.present(picker, animated: true)
  }

  private func interruptCapture() {
    guard pendingResult != nil else { return }
    activePicker?.dismiss(animated: false)
    fail(
      code: "CAMERA_INTERRUPTED",
      message: "拍摄因应用进入后台而中断，请重新拍摄。",
      details: nil
    )
  }

  private func failPermission() {
    fail(
      code: "CAMERA_PERMISSION_DENIED",
      message: "相机权限被拒绝，请在系统设置中允许 DD 使用相机。",
      details: ["canOpenSettings": true]
    )
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(
        FlutterError(
          code: "APP_SETTINGS_UNAVAILABLE",
          message: "iOS 无法打开 DD 的系统设置页面。",
          details: nil
        )
      )
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      if opened {
        result(nil)
      } else {
        result(
          FlutterError(
            code: "APP_SETTINGS_UNAVAILABLE",
            message: "iOS 未能打开 DD 的系统设置页面。",
            details: nil
          )
        )
      }
    }
  }

  private func writeCapturedPhoto(_ image: UIImage) throws -> URL {
    guard let data = image.jpegData(compressionQuality: 0.92), !data.isEmpty else {
      throw CameraFailure(
        code: "CAMERA_ENCODE_FAILED",
        message: "iOS 无法编码拍摄的照片。"
      )
    }
    let root = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("dd_camera", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let file = directory.appendingPathComponent(
      "DD-camera-\(UUID().uuidString).jpg",
      isDirectory: false
    )
    try data.write(to: file, options: .atomic)
    return file
  }

  private func succeed(_ value: Any?) {
    removeBackgroundObserver()
    let result = pendingResult
    pendingResult = nil
    activePicker = nil
    result?(value)
  }

  private func fail(code: String, message: String, details: Any?) {
    removeBackgroundObserver()
    let result = pendingResult
    pendingResult = nil
    activePicker = nil
    result?(FlutterError(code: code, message: message, details: details))
  }

  private func removeBackgroundObserver() {
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
      backgroundObserver = nil
    }
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })
    return topViewController(from: window?.rootViewController)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    return controller
  }
}

extension CameraCaptureService: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    succeed(nil)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else {
      fail(
        code: "CAMERA_CAPTURE_FAILED",
        message: "iOS 相机没有返回拍摄照片。",
        details: nil
      )
      return
    }
    do {
      let file = try writeCapturedPhoto(image)
      succeed(file.path)
    } catch let error as CameraFailure {
      fail(code: error.code, message: error.message, details: nil)
    } catch {
      fail(
        code: "CAMERA_CAPTURE_FAILED",
        message: "保存拍摄照片失败：\(error.localizedDescription)",
        details: nil
      )
    }
  }
}

private struct CameraFailure: Error {
  let code: String
  let message: String
}
