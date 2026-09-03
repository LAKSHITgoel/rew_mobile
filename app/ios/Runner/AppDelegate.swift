import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
