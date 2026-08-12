import Flutter
import Foundation
import MobileCoreServices
import Photos
import UIKit

/// iOS implementation for `dd/media_export`.
///
/// Large file/video operations always receive a local path from Dart. The
/// service passes that URL to Photos, Files, the share sheet or a system file
/// handler; it never reads a whole media file into Data.
final class MediaExportService: NSObject, DDNativeService {
  static let pluginKey = "DDMediaExportService"
  private static let shared = MediaExportService()
  private static let channelName = "dd/media_export"

  private var pendingExportResult: FlutterResult?
  private var interactionController: UIDocumentInteractionController?

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
    case "saveImageToGallery":
      saveImageToGallery(call.arguments, result: result)
    case "saveLocalVideoToGallery":
      saveLocalVideoToGallery(call.arguments, result: result)
    case "exportLocalFile":
      exportLocalFile(call.arguments, result: result)
    case "shareLocalFile":
      shareLocalFile(call.arguments, result: result)
    case "openLocalFile":
      openLocalFile(call.arguments, result: result)
    case "copyLocalFileToClipboard":
      copyLocalFileToClipboard(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func saveImageToGallery(_ rawArguments: Any?, result: @escaping FlutterResult) {
    let arguments = rawArguments as? [String: Any] ?? [:]
    guard let typed = arguments["bytes"] as? FlutterStandardTypedData,
      !typed.data.isEmpty
    else {
      result(
        FlutterError(
          code: "MEDIA_EXPORT_INVALID_IMAGE",
          message: "待保存的图片内容为空。",
          details: nil
        )
      )
      return
    }
    let mimeType = (arguments["mimeType"] as? String ?? "").lowercased()
    guard mimeType.hasPrefix("image/") else {
      result(
        FlutterError(
          code: "MEDIA_EXPORT_INVALID_IMAGE",
          message: "待保存内容不是受支持的图片。",
          details: ["mimeType": mimeType]
        )
      )
      return
    }
    let fileName = safeFileName(arguments["fileName"] as? String, fallback: "DD-image")

    withPhotoAddAuthorization(result: result) { [weak self] in
      guard let self else { return }
      var localIdentifier: String?
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileName
        request.addResource(with: .photo, data: typed.data, options: options)
        localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
      } completionHandler: { success, error in
        DispatchQueue.main.async {
          if success {
            result("ph://\(localIdentifier ?? "saved")")
          } else {
            result(
              FlutterError(
                code: "MEDIA_EXPORT_FAILED",
                message: error?.localizedDescription ?? "iOS 无法将图片保存到系统相册。",
                details: nil
              )
            )
          }
        }
      }
    }
  }

  private func saveLocalVideoToGallery(
    _ rawArguments: Any?,
    result: @escaping FlutterResult
  ) {
    do {
      let file = try checkedFileURL(rawArguments)
      withPhotoAddAuthorization(result: result) {
        var localIdentifier: String?
        PHPhotoLibrary.shared().performChanges {
          let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(
            atFileURL: file
          )
          localIdentifier = request?.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { success, error in
          DispatchQueue.main.async {
            if success {
              result(true)
            } else {
              result(
                FlutterError(
                  code: "MEDIA_EXPORT_FAILED",
                  message: error?.localizedDescription ?? "iOS 无法将视频保存到系统相册。",
                  details: ["asset": localIdentifier as Any]
                )
              )
            }
          }
        }
      }
    } catch let error as MediaExportFailure {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
    } catch {
      result(
        FlutterError(
          code: "MEDIA_EXPORT_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func exportLocalFile(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard pendingExportResult == nil else {
      result(
        FlutterError(
          code: "MEDIA_EXPORT_BUSY",
          message: "已有文件导出面板正在显示。",
          details: nil
        )
      )
      return
    }
    do {
      let file = try checkedFileURL(rawArguments)
      guard let presenter = topViewController() else {
        throw MediaExportFailure(
          code: "MEDIA_EXPORT_UNAVAILABLE",
          message: "当前没有可显示文件导出面板的 iOS 页面。",
          details: nil
        )
      }
      pendingExportResult = result
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: file, in: .exportToService)
      }
      picker.delegate = self
      picker.presentationController?.delegate = self
      presenter.present(picker, animated: true)
    } catch let error as MediaExportFailure {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
    } catch {
      result(
        FlutterError(
          code: "MEDIA_EXPORT_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func shareLocalFile(_ rawArguments: Any?, result: @escaping FlutterResult) {
    do {
      let file = try checkedFileURL(rawArguments)
      guard let presenter = topViewController() else {
        throw MediaExportFailure(
          code: "MEDIA_SHARE_UNAVAILABLE",
          message: "当前没有可显示系统分享面板的 iOS 页面。",
          details: nil
        )
      }
      let controller = UIActivityViewController(
        activityItems: [file],
        applicationActivities: nil
      )
      if let popover = controller.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX,
          y: presenter.view.bounds.midY,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      controller.completionWithItemsHandler = { _, completed, _, error in
        DispatchQueue.main.async {
          if let error {
            result(
              FlutterError(
                code: "MEDIA_SHARE_FAILED",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else if completed {
            result(true)
          } else {
            result(
              FlutterError(
                code: "MEDIA_SHARE_CANCELLED",
                message: "已取消系统分享。",
                details: nil
              )
            )
          }
        }
      }
      presenter.present(controller, animated: true)
    } catch let error as MediaExportFailure {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
    } catch {
      result(
        FlutterError(
          code: "MEDIA_SHARE_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func openLocalFile(_ rawArguments: Any?, result: @escaping FlutterResult) {
    do {
      let file = try checkedFileURL(rawArguments)
      guard let presenter = topViewController() else {
        throw MediaExportFailure(
          code: "MEDIA_OPEN_UNAVAILABLE",
          message: "当前没有可显示系统文件处理器的 iOS 页面。",
          details: nil
        )
      }
      let arguments = rawArguments as? [String: Any] ?? [:]
      let controller = UIDocumentInteractionController(url: file)
      controller.delegate = self
      if let mime = arguments["mimeType"] as? String,
        let typeIdentifier = UTTypeCreatePreferredIdentifierForTag(
          kUTTagClassMIMEType,
          mime as CFString,
          nil
        )?.takeRetainedValue()
      {
        controller.uti = typeIdentifier as String
      }
      interactionController = controller
      let presented = controller.presentOptionsMenu(
        from: presenter.view.bounds,
        in: presenter.view,
        animated: true
      )
      if presented {
        result(true)
      } else {
        interactionController = nil
        throw MediaExportFailure(
          code: "MEDIA_OPEN_UNAVAILABLE",
          message: "iOS 没有找到可处理该文件的系统应用。",
          details: nil
        )
      }
    } catch let error as MediaExportFailure {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
    } catch {
      result(
        FlutterError(
          code: "MEDIA_OPEN_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func copyLocalFileToClipboard(
    _ rawArguments: Any?,
    result: @escaping FlutterResult
  ) {
    do {
      let file = try checkedFileURL(rawArguments)
      guard let provider = NSItemProvider(contentsOf: file) else {
        throw MediaExportFailure(
          code: "MEDIA_COPY_UNAVAILABLE",
          message: "iOS 无法为该文件创建剪贴板数据提供器。",
          details: nil
        )
      }
      UIPasteboard.general.setItemProviders(
        [provider],
        localOnly: true,
        expirationDate: Date().addingTimeInterval(15 * 60)
      )
      result(true)
    } catch let error as MediaExportFailure {
      result(FlutterError(code: error.code, message: error.message, details: error.details))
    } catch {
      result(
        FlutterError(
          code: "MEDIA_COPY_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func withPhotoAddAuthorization(
    result: @escaping FlutterResult,
    action: @escaping () -> Void
  ) {
    if #available(iOS 14.0, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      switch status {
      case .authorized, .limited:
        action()
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
          DispatchQueue.main.async {
            if newStatus == .authorized || newStatus == .limited {
              action()
            } else {
              result(
                FlutterError(
                  code: "PHOTO_LIBRARY_ADD_PERMISSION_DENIED",
                  message: "相册写入权限被拒绝，请在系统设置中允许 DD 添加照片。",
                  details: ["canOpenSettings": true]
                )
              )
            }
          }
        }
      case .denied, .restricted:
        result(
          FlutterError(
            code: "PHOTO_LIBRARY_ADD_PERMISSION_DENIED",
            message: "相册写入权限被拒绝，请在系统设置中允许 DD 添加照片。",
            details: ["canOpenSettings": true]
          )
        )
      @unknown default:
        result(
          FlutterError(
            code: "PHOTO_LIBRARY_PERMISSION_UNKNOWN",
            message: "iOS 返回了未知的相册权限状态。",
            details: nil
          )
        )
      }
      return
    }

    let status = PHPhotoLibrary.authorizationStatus()
    if status == .authorized {
      action()
      return
    }
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization { newStatus in
        DispatchQueue.main.async {
          if newStatus == .authorized {
            action()
          } else {
            result(
              FlutterError(
                code: "PHOTO_LIBRARY_ADD_PERMISSION_DENIED",
                message: "相册写入权限被拒绝，请在系统设置中允许 DD 保存媒体。",
                details: ["canOpenSettings": true]
              )
            )
          }
        }
      }
      return
    }
    result(
      FlutterError(
        code: "PHOTO_LIBRARY_ADD_PERMISSION_DENIED",
        message: "相册写入权限被拒绝，请在系统设置中允许 DD 保存媒体。",
        details: ["canOpenSettings": true]
      )
    )
  }

  private func checkedFileURL(_ rawArguments: Any?) throws -> URL {
    let arguments = rawArguments as? [String: Any] ?? [:]
    guard let rawPath = arguments["path"] as? String,
      !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MediaExportFailure(
        code: "MEDIA_FILE_INVALID_PATH",
        message: "没有可用的本地文件路径。",
        details: nil
      )
    }
    let file = URL(fileURLWithPath: rawPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw MediaExportFailure(
        code: "MEDIA_FILE_NOT_FOUND",
        message: "待处理的本地文件不存在。",
        details: ["path": rawPath]
      )
    }
    return file
  }

  private func safeFileName(_ raw: String?, fallback: String) -> String {
    let value = (raw ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
      .joined(separator: "_")
    return value.isEmpty ? fallback : String(value.prefix(160))
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

  private func finishExport(_ value: Any?) {
    let result = pendingExportResult
    pendingExportResult = nil
    result?(value)
  }
}

extension MediaExportService: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    finishExport(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingExportResult
    pendingExportResult = nil
    result?(
      FlutterError(
        code: "MEDIA_EXPORT_CANCELLED",
        message: "已取消文件导出。",
        details: nil
      )
    )
  }
}

extension MediaExportService: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard pendingExportResult != nil else { return }
    let result = pendingExportResult
    pendingExportResult = nil
    result?(
      FlutterError(
        code: "MEDIA_EXPORT_CANCELLED",
        message: "已取消文件导出。",
        details: nil
      )
    )
  }
}

extension MediaExportService: UIDocumentInteractionControllerDelegate {
  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    topViewController() ?? UIViewController()
  }

  func documentInteractionControllerDidDismissOptionsMenu(
    _ controller: UIDocumentInteractionController
  ) {
    interactionController = nil
  }
}

private struct MediaExportFailure: Error {
  let code: String
  let message: String
  let details: Any?
}
