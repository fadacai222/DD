import Flutter
import Foundation
import MobileCoreServices
import Photos
import PhotosUI
import UIKit

/// iOS implementation for `dd/file_picker`.
///
/// Selected documents and Photos assets are copied to an app-owned cache path.
/// Only path/name/MIME/size metadata crosses the Flutter channel; file bytes do
/// not. This keeps large videos out of the Dart heap and also avoids retaining
/// security-scoped/document-provider URLs after their callback lifetime ends.
final class FilePickerService: NSObject, DDNativeService {
  static let pluginKey = "DDFilePickerService"
  private static let shared = FilePickerService()
  private static let channelName = "dd/file_picker"

  private var pendingResult: FlutterResult?
  private var maxFiles = 1
  private var maxBytes: Int64?
  private var acceptedMimeTypes: [String] = []
  private var legacyPhotoPicker: UIImagePickerController?

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
    case "openFiles":
      openFiles(call.arguments, result: result)
    case "openAppSettings":
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func openFiles(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "FILE_PICKER_BUSY",
          message: "已有文件选择器正在显示。",
          details: nil
        )
      )
      return
    }
    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "FILE_PICKER_UNAVAILABLE",
          message: "当前没有可显示文件选择器的 iOS 页面。",
          details: nil
        )
      )
      return
    }

    let arguments = rawArguments as? [String: Any] ?? [:]
    let allowMultiple = arguments["allowMultiple"] as? Bool ?? false
    maxFiles = max(1, number(arguments["maxFiles"])?.intValue ?? (allowMultiple ? 500 : 1))
    maxBytes = number(arguments["maxBytes"])?.int64Value
    acceptedMimeTypes = (arguments["mimeTypes"] as? [String] ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    let source = (arguments["source"] as? String ?? "files").lowercased()

    pendingResult = result
    if source == "photos" {
      presentPhotosPicker(from: presenter, allowMultiple: allowMultiple)
    } else {
      presentDocumentPicker(from: presenter, allowMultiple: allowMultiple)
    }
  }

  private func presentDocumentPicker(
    from presenter: UIViewController,
    allowMultiple: Bool
  ) {
    let identifiers = acceptedMimeTypes.compactMap(typeIdentifier(forMimeType:))
    let picker = UIDocumentPickerViewController(
      documentTypes: identifiers.isEmpty ? [kUTTypeItem as String] : identifiers,
      in: .import
    )
    picker.allowsMultipleSelection = allowMultiple
    picker.delegate = self
    picker.presentationController?.delegate = self
    presenter.present(picker, animated: true)
  }

  private func presentPhotosPicker(
    from presenter: UIViewController,
    allowMultiple: Bool
  ) {
    if #available(iOS 14.0, *) {
      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.selectionLimit = allowMultiple ? maxFiles : 1
      configuration.preferredAssetRepresentationMode = .current
      configuration.filter = photoFilter()
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      picker.presentationController?.delegate = self
      presenter.present(picker, animated: true)
      return
    }

    // PHPicker is iOS 14+. iOS 13 has no system multi-select Photos picker.
    // Keep the fallback system-native and single-select instead of inventing a
    // custom PhotoKit browser. The current selection still remains path-based.
    let status = PHPhotoLibrary.authorizationStatus()
    if status == .authorized {
      presentLegacyPhotoPicker(from: presenter)
      return
    }
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization { [weak self] newStatus in
        DispatchQueue.main.async {
          guard let self else { return }
          if newStatus == .authorized {
            self.presentLegacyPhotoPicker(from: presenter)
          } else {
            self.fail(
              code: "PHOTO_LIBRARY_PERMISSION_DENIED",
              message: "照片权限被拒绝，请在系统设置中允许 DD 访问照片。",
              details: ["canOpenSettings": true]
            )
          }
        }
      }
      return
    }
    fail(
      code: "PHOTO_LIBRARY_PERMISSION_DENIED",
      message: "照片权限被拒绝，请在系统设置中允许 DD 访问照片。",
      details: ["canOpenSettings": true]
    )
  }

  private func presentLegacyPhotoPicker(from presenter: UIViewController) {
    guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
      fail(
        code: "PHOTO_LIBRARY_UNAVAILABLE",
        message: "当前设备无法打开系统照片选择器。",
        details: nil
      )
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .photoLibrary
    picker.mediaTypes = legacyPhotoMediaTypes()
    picker.delegate = self
    picker.presentationController?.delegate = self
    legacyPhotoPicker = picker
    presenter.present(picker, animated: true)
  }

  private func legacyPhotoMediaTypes() -> [String] {
    let wantsImages = acceptedMimeTypes.isEmpty || acceptedMimeTypes.contains { $0.hasPrefix("image/") }
    let wantsVideos = acceptedMimeTypes.isEmpty || acceptedMimeTypes.contains { $0.hasPrefix("video/") }
    var types: [String] = []
    if wantsImages { types.append(kUTTypeImage as String) }
    if wantsVideos { types.append(kUTTypeMovie as String) }
    return types.isEmpty ? [kUTTypeImage as String, kUTTypeMovie as String] : types
  }

  @available(iOS 14.0, *)
  private func photoFilter() -> PHPickerFilter? {
    let wantsImages = acceptedMimeTypes.isEmpty || acceptedMimeTypes.contains { $0.hasPrefix("image/") }
    let wantsVideos = acceptedMimeTypes.isEmpty || acceptedMimeTypes.contains { $0.hasPrefix("video/") }
    if wantsImages && wantsVideos { return .any(of: [.images, .videos]) }
    if wantsVideos { return .videos }
    if wantsImages { return .images }
    return nil
  }

  private func copyPickedURLs(_ urls: [URL]) {
    let selected = Array(urls.prefix(maxFiles))
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      do {
        let files = try selected.map { try self.copyToPickerCache($0, suggestedName: nil) }
        DispatchQueue.main.async { self.succeed(files) }
      } catch let error as PickerFailure {
        DispatchQueue.main.async {
          self.fail(code: error.code, message: error.message, details: error.details)
        }
      } catch {
        DispatchQueue.main.async {
          self.fail(
            code: "FILE_PICKER_COPY_FAILED",
            message: "无法缓存所选文件：\(error.localizedDescription)",
            details: nil
          )
        }
      }
    }
  }

  private func copyToPickerCache(
    _ sourceURL: URL,
    suggestedName: String?
  ) throws -> [String: Any] {
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { sourceURL.stopAccessingSecurityScopedResource() }
    }

    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
    let size = Int64(values.fileSize ?? 0)
    if let maxBytes, size > maxBytes {
      throw PickerFailure(
        code: "FILE_TOO_LARGE",
        message: "所选文件超过当前允许的大小。",
        details: ["size": size, "maxBytes": maxBytes]
      )
    }

    let originalName = safeFileName(
      suggestedName ?? values.name ?? sourceURL.lastPathComponent,
      fallbackExtension: sourceURL.pathExtension
    )
    let directory = try pickerCacheDirectory()
    let destination = directory.appendingPathComponent(
      "\(UUID().uuidString)-\(originalName)",
      isDirectory: false
    )
    try FileManager.default.copyItem(at: sourceURL, to: destination)

    let copiedValues = try destination.resourceValues(forKeys: [.fileSizeKey])
    let copiedSize = Int64(copiedValues.fileSize ?? 0)
    if let maxBytes, copiedSize > maxBytes {
      try? FileManager.default.removeItem(at: destination)
      throw PickerFailure(
        code: "FILE_TOO_LARGE",
        message: "所选文件超过当前允许的大小。",
        details: ["size": copiedSize, "maxBytes": maxBytes]
      )
    }

    var payload: [String: Any] = [
      "path": destination.path,
      "name": originalName,
      "size": copiedSize,
    ]
    if let mime = mimeType(for: destination) {
      payload["mimeType"] = mime
    }
    return payload
  }

  private func pickerCacheDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("dd_picker", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return directory
  }

  private func safeFileName(_ raw: String, fallbackExtension: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:\0")
    var value = raw
      .components(separatedBy: forbidden)
      .joined(separator: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { value = "DD-media" }
    if URL(fileURLWithPath: value).pathExtension.isEmpty && !fallbackExtension.isEmpty {
      value += ".\(fallbackExtension)"
    }
    return String(value.prefix(160))
  }

  private func typeIdentifier(forMimeType mimeType: String) -> String? {
    guard let identifier = UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassMIMEType,
      mimeType as CFString,
      nil
    )?.takeRetainedValue() else {
      return nil
    }
    return identifier as String
  }

  private func mimeType(for url: URL) -> String? {
    let ext = url.pathExtension
    guard !ext.isEmpty,
      let identifier = UTTypeCreatePreferredIdentifierForTag(
        kUTTagClassFilenameExtension,
        ext as CFString,
        nil
      )?.takeRetainedValue(),
      let mime = UTTypeCopyPreferredTagWithClass(
        identifier,
        kUTTagClassMIMEType
      )?.takeRetainedValue()
    else {
      return nil
    }
    return mime as String
  }

  private func number(_ value: Any?) -> NSNumber? {
    if let value = value as? NSNumber { return value }
    if let value = value as? Int { return NSNumber(value: value) }
    if let value = value as? Int64 { return NSNumber(value: value) }
    return nil
  }

  private func succeed(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    legacyPhotoPicker = nil
    result?(value)
  }

  private func fail(code: String, message: String, details: Any?) {
    let result = pendingResult
    pendingResult = nil
    legacyPhotoPicker = nil
    result?(FlutterError(code: code, message: message, details: details))
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

extension FilePickerService: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    if urls.isEmpty {
      succeed([])
      return
    }
    copyPickedURLs(urls)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    succeed([])
  }
}

@available(iOS 14.0, *)
extension FilePickerService: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let selected = Array(results.prefix(maxFiles))
    guard !selected.isEmpty else {
      succeed([])
      return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var copied: [(Int, [String: Any])] = []
    var failure: PickerFailure?

    for (index, item) in selected.enumerated() {
      let provider = item.itemProvider
      guard let typeIdentifier = preferredTypeIdentifier(from: provider) else {
        lock.lock()
        if failure == nil {
          failure = PickerFailure(
            code: "PHOTO_ASSET_UNSUPPORTED",
            message: "所选照片或视频没有可读取的文件表示。",
            details: nil
          )
        }
        lock.unlock()
        continue
      }

      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
        defer { group.leave() }
        guard let self else { return }
        do {
          if let error { throw error }
          guard let url else {
            throw PickerFailure(
              code: "PHOTO_ASSET_UNAVAILABLE",
              message: "iOS 没有返回所选媒体的临时文件。",
              details: nil
            )
          }
          // The item-provider URL is temporary and can disappear as soon as
          // this callback returns. Copy it synchronously here, without Data.
          let value = try self.copyToPickerCache(
            url,
            suggestedName: provider.suggestedName
          )
          lock.lock()
          copied.append((index, value))
          lock.unlock()
        } catch let error as PickerFailure {
          lock.lock()
          if failure == nil { failure = error }
          lock.unlock()
        } catch {
          lock.lock()
          if failure == nil {
            failure = PickerFailure(
              code: "PHOTO_ASSET_COPY_FAILED",
              message: "无法缓存所选媒体：\(error.localizedDescription)",
              details: nil
            )
          }
          lock.unlock()
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      if let failure {
        self.fail(code: failure.code, message: failure.message, details: failure.details)
        return
      }
      self.succeed(copied.sorted { $0.0 < $1.0 }.map { $0.1 })
    }
  }

  private func preferredTypeIdentifier(from provider: NSItemProvider) -> String? {
    let identifiers = provider.registeredTypeIdentifiers
    let preferred = identifiers.first { identifier in
      UTTypeConformsTo(identifier as CFString, kUTTypeMovie) ||
        UTTypeConformsTo(identifier as CFString, kUTTypeImage)
    }
    return preferred ?? identifiers.first
  }
}

extension FilePickerService: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    succeed([])
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    let sourceURL = (info[.mediaURL] as? URL) ?? (info[.imageURL] as? URL)
    guard let sourceURL else {
      fail(
        code: "PHOTO_ASSET_UNAVAILABLE",
        message: "iOS 13 没有返回所选媒体的文件路径。",
        details: nil
      )
      return
    }
    copyPickedURLs([sourceURL])
  }
}

extension FilePickerService: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if pendingResult != nil { succeed([]) }
  }
}

private struct PickerFailure: Error {
  let code: String
  let message: String
  let details: Any?
}
