import Flutter

protocol DDNativeService {
  static var pluginKey: String { get }
  static func register(with registrar: FlutterPluginRegistrar)
}

enum NativeServiceRegistrar {
  static func register(with registry: FlutterPluginRegistry) {
    register(NativeRouteService.self, with: registry)
    register(PushNotificationService.self, with: registry)
    register(FilePickerService.self, with: registry)
    register(CameraCaptureService.self, with: registry)
    register(MediaExportService.self, with: registry)
    register(CallPlatformService.self, with: registry)
  }

  private static func register<Service: DDNativeService>(
    _ service: Service.Type,
    with registry: FlutterPluginRegistry
  ) {
    guard let registrar = registry.registrar(forPlugin: Service.pluginKey) else {
      return
    }
    Service.register(with: registrar)
  }
}
