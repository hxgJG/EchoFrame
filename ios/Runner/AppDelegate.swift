import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "LumioAppStoragePlugin") {
      LumioAppStoragePlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "LumioMediaLibraryPlugin") {
      LumioMediaLibraryPlugin.register(with: registrar)
    }
    if let registrar = registrar(forPlugin: "LumioPlaybackPlugin") {
      LumioPlaybackPlugin.register(with: registrar)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
