import UIKit
import Flutter
import UserNotifications

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {

  static var bgChannel: FlutterMethodChannel?
  var bgCompletionHandler: (() -> Void)?

  // MARK: - App launch

override func application(
  _ application: UIApplication,
  didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
  let controller = window?.rootViewController as! FlutterViewController

  // Register plugins first
  GeneratedPluginRegistrant.register(with: self)

  // Single channel used by Dart
  let channel = FlutterMethodChannel(
    name: "background_uploader",
    binaryMessenger: controller.binaryMessenger
  )
  AppDelegate.bgChannel = channel

  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "start":
      guard
        let args = call.arguments as? [String: Any],
        let filePath  = args["filePath"] as? String,
        let presignedUrl = args["presignedUrl"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "filePath/presignedUrl missing", details: nil))
        return
      }
      let headers = args["headers"] as? [String: String] ?? [:]
      let method  = (args["method"] as? String) ?? "PUT"

      do {
        try BackgroundUploader.shared.start(
          filePath: filePath,
          presignedUrl: presignedUrl,
          headers: headers,
          method: method
        )
      result(true)
      } catch {
        result(FlutterError(code: "bg_start_failed", message: error.localizedDescription, details: nil))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Foreground notifications
  if #available(iOS 10.0, *) {
    UNUserNotificationCenter.current().delegate = self
  }

  return super.application(application, didFinishLaunchingWithOptions: launchOptions)
}

  

  // MARK: - Background URLSession wake

  // iOS relaunches/wakes your app to deliver URLSession events for the background session.
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // Reconnect the background session and save the handler to call when done.
    BackgroundUploader.shared.restore(identifier: identifier)
    self.bgCompletionHandler = completionHandler
  }

}

// MARK: - BackgroundUploader (embedded to avoid Xcode project edits)


