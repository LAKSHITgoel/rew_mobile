import Flutter
import UIKit
import rewcore_ffi

/// Keeps rewcore's C entry points in the app binary.
///
/// Dart resolves them at run time with DynamicLibrary.process(), so nothing
/// references them at link time — and on iOS the core is a static library, whose
/// unreferenced objects the linker simply drops. That produced an app that built
/// and launched perfectly and could not measure anything. All seven entry points
/// live in one translation unit, so touching one keeps the lot.
enum RewcoreLink {
  static let version: String = {
    guard let v = rew_version() else { return "" }
    return String(cString: v)
  }()
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // The reference is the point; see RewcoreLink.
    if RewcoreLink.version.isEmpty {
      NSLog("rewcore did not report a version — the native core may be missing")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The audio and files channels live in the app rather than in a pub package
    // (the Android side is arranged the same way), so they are registered by
    // hand — GeneratedPluginRegistrant only knows about plugins from pubspec.
    let registry = engineBridge.pluginRegistry
    if let registrar = registry.registrar(forPlugin: "RewAudioPlugin") {
      RewAudioPlugin.register(with: registrar)
    }
    if let registrar = registry.registrar(forPlugin: "RewFilesPlugin") {
      RewFilesPlugin.register(with: registrar)
    }
  }
}
