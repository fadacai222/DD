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
  private var preserveLivePhoto = false
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
    preserveLivePhoto = arguments["preserveLivePhoto"] as? Bool ?? false
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

  private func mimeType(forTypeIdentifier identifier: String) -> String? {
    guard let mime = UTTypeCopyPreferredTagWithClass(
      identifier as CFString,
      kUTTagClassMIMEType
    )?.takeRetainedValue() else {
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
      group.enter()
      copyPhotoPickerResult(item) { result in
        defer { group.leave() }
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let value):
          copied.append((index, value))
        case .failure(let error):
          if failure == nil { failure = error }
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      if let failure {
        copied.forEach { self.removeCachedFiles(from: $0.1) }
        self.fail(code: failure.code, message: failure.message, details: failure.details)
        return
      }
      self.succeed(copied.sorted { $0.0 < $1.0 }.map { $0.1 })
    }
  }

  private func copyPhotoPickerResult(
    _ item: PHPickerResult,
    completion: @escaping (Result<[String: Any], PickerFailure>) -> Void
  ) {
    let provider = item.itemProvider
    if preserveLivePhoto && provider.canLoadObject(ofClass: PHLivePhoto.self) {
      provider.loadObject(ofClass: PHLivePhoto.self) { [weak self] object, error in
        guard let self else { return }
        if let error {
          completion(.failure(PickerFailure(
            code: "LIVE_PHOTO_REPRESENTATION_UNAVAILABLE",
            message: "无法读取 Live Photo 成对资源：\(error.localizedDescription)",
            details: nil
          )))
          return
        }
        guard let livePhoto = object as? PHLivePhoto else {
          completion(.failure(PickerFailure(
            code: "LIVE_PHOTO_REPRESENTATION_UNAVAILABLE",
            message: "iOS 未返回可导出的 Live Photo 表示。",
            details: nil
          )))
          return
        }
        self.copyLivePhotoToPickerCache(
          livePhoto,
          assetIdentifier: item.assetIdentifier,
          completion: completion
        )
      }
      return
    }

    guard let typeIdentifier = preferredTypeIdentifier(from: provider) else {
      completion(.failure(PickerFailure(
        code: "PHOTO_ASSET_UNSUPPORTED",
        message: "所选照片或视频没有可读取的文件表示。",
        details: nil
      )))
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
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
        var value = try self.copyToPickerCache(
          url,
          suggestedName: provider.suggestedName
        )
        value["kind"] = self.mediaKind(forTypeIdentifier: typeIdentifier)
        if let assetIdentifier = item.assetIdentifier {
          value["assetIdentifier"] = assetIdentifier
        }
        completion(.success(value))
      } catch let error as PickerFailure {
        completion(.failure(error))
      } catch {
        completion(.failure(PickerFailure(
          code: "PHOTO_ASSET_COPY_FAILED",
          message: "无法缓存所选媒体：\(error.localizedDescription)",
          details: nil
        )))
      }
    }
  }

  private func copyLivePhotoToPickerCache(
    _ livePhoto: PHLivePhoto,
    assetIdentifier: String?,
    completion: @escaping (Result<[String: Any], PickerFailure>) -> Void
  ) {
    guard let resources = livePhotoResourcePair(from: PHAssetResource.assetResources(for: livePhoto)) else {
      completion(.failure(PickerFailure(
        code: "LIVE_PHOTO_COMPONENTS_UNAVAILABLE",
        message: "Live Photo 缺少匹配的静态图或 motion 组件。",
        details: nil
      )))
      return
    }

    writeLivePhotoResource(resources.still, component: "still") { [weak self] stillResult in
      guard let self else { return }
      switch stillResult {
      case .failure(let error):
        completion(.failure(error))
      case .success(let still):
        self.writeLivePhotoResource(resources.motion, component: "motion") { motionResult in
          switch motionResult {
          case .failure(let error):
            self.removeCachedFiles(from: still)
            completion(.failure(error))
          case .success(let motion):
            let stillSize = self.number(still["size"])?.int64Value ?? 0
            let motionSize = self.number(motion["size"])?.int64Value ?? 0
            let totalSize = stillSize + motionSize
            if let maxBytes = self.maxBytes, totalSize > maxBytes {
              self.removeCachedFiles(from: still)
              self.removeCachedFiles(from: motion)
              completion(.failure(PickerFailure(
                code: "LIVE_PHOTO_TOO_LARGE",
                message: "Live Photo 静态图与 motion 组件总大小超过当前允许的大小。",
                details: [
                  "stillSize": stillSize,
                  "motionSize": motionSize,
                  "totalSize": totalSize,
                  "maxBytes": maxBytes,
                ]
              )))
              return
            }
            var payload: [String: Any] = [
              "kind": "livePhoto",
              "still": still,
              "motion": motion,
            ]
            if let assetIdentifier, !assetIdentifier.isEmpty {
              payload["assetIdentifier"] = assetIdentifier
            }
            completion(.success(payload))
          }
        }
      }
    }
  }

  private func livePhotoResourcePair(
    from resources: [PHAssetResource]
  ) -> (still: PHAssetResource, motion: PHAssetResource)? {
    let currentStill = resources.first { $0.type == .fullSizePhoto }
    let currentMotion = resources.first { $0.type == .fullSizePairedVideo }
    if let currentStill, let currentMotion {
      return (currentStill, currentMotion)
    }
    let originalStill = resources.first { $0.type == .photo }
    let originalMotion = resources.first { $0.type == .pairedVideo }
    if let originalStill, let originalMotion {
      return (originalStill, originalMotion)
    }
    return nil
  }

  private func writeLivePhotoResource(
    _ resource: PHAssetResource,
    component: String,
    completion: @escaping (Result<[String: Any], PickerFailure>) -> Void
  ) {
    let destination: URL
    let originalName: String
    do {
      let fallbackExtension = component == "motion" ? "mov" : "heic"
      originalName = safeFileName(
        resource.originalFilename,
        fallbackExtension: fallbackExtension
      )
      destination = try pickerCacheDirectory().appendingPathComponent(
        "\(UUID().uuidString)-\(originalName)",
        isDirectory: false
      )
    } catch {
      completion(.failure(PickerFailure(
        code: "LIVE_PHOTO_CACHE_UNAVAILABLE",
        message: "无法创建 Live Photo 缓存路径：\(error.localizedDescription)",
        details: ["component": component]
      )))
      return
    }

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: destination,
      options: options
    ) { [weak self] error in
      guard let self else { return }
      if let error {
        try? FileManager.default.removeItem(at: destination)
        completion(.failure(PickerFailure(
          code: "LIVE_PHOTO_COMPONENT_COPY_FAILED",
          message: "无法缓存 Live Photo 的 \(component) 组件：\(error.localizedDescription)",
          details: ["component": component]
        )))
        return
      }
      do {
        let normalized = try self.normalizeLivePhotoStillIfNeeded(
          destination,
          originalName: originalName,
          component: component
        )
        let values = try normalized.url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        if let maxBytes = self.maxBytes, size > maxBytes {
          try? FileManager.default.removeItem(at: normalized.url)
          completion(.failure(PickerFailure(
            code: "FILE_TOO_LARGE",
            message: "Live Photo 的 \(component) 组件超过当前允许的大小。",
            details: [
              "component": component,
              "size": size,
              "maxBytes": maxBytes,
            ]
          )))
          return
        }
        var payload: [String: Any] = [
          "path": normalized.url.path,
          "name": normalized.name,
          "size": size,
        ]
        if let mime = normalized.mimeType ?? self.mimeType(forTypeIdentifier: resource.uniformTypeIdentifier) {
          payload["mimeType"] = mime
        }
        completion(.success(payload))
      } catch {
        try? FileManager.default.removeItem(at: destination)
        completion(.failure(PickerFailure(
          code: "LIVE_PHOTO_COMPONENT_COPY_FAILED",
          message: "无法校验 Live Photo 的 \(component) 缓存：\(error.localizedDescription)",
          details: ["component": component]
        )))
      }
    }
  }

  private func normalizeLivePhotoStillIfNeeded(
    _ source: URL,
    originalName: String,
    component: String
  ) throws -> (url: URL, name: String, mimeType: String?) {
    guard component == "still", let image = UIImage(contentsOfFile: source.path) else {
      return (source, originalName, nil)
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.92) else {
      return (source, originalName, nil)
    }
    let output = source.deletingPathExtension().appendingPathExtension("jpg")
    try jpeg.write(to: output, options: .atomic)
    try? FileManager.default.removeItem(at: source)
    let base = (originalName as NSString).deletingPathExtension
    return (output, "\(base.isEmpty ? "DD-live-photo" : base).jpg", "image/jpeg")
  }

  private func removeCachedFiles(from payload: [String: Any]) {
    if let path = payload["path"] as? String, !path.isEmpty {
      try? FileManager.default.removeItem(atPath: path)
    }
    for key in ["still", "motion"] {
      if let nested = payload[key] as? [String: Any] {
        removeCachedFiles(from: nested)
      }
    }
  }

  private func mediaKind(forTypeIdentifier identifier: String) -> String {
    if UTTypeConformsTo(identifier as CFString, kUTTypeMovie) {
      return "video"
    }
    return "photo"
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
