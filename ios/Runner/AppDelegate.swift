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

    // MethodChannel for iOS background uploads
    AppDelegate.bgChannel = FlutterMethodChannel(
      name: "bg_upload",
      binaryMessenger: controller.binaryMessenger
    )

    // Handle "start" calls from Dart (IOSBgUpload.start)
    bgChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "start",
            let args = call.arguments as? [String: Any],
            let filePath = args["filePath"] as? String,
            let url = args["url"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "Missing start args", details: nil))
        return
      }
      let method = (args["method"] as? String) ?? "PUT"
      let headers = (args["headers"] as? [String:String]) ?? [:]

    BackgroundUploader.shared.start(
      filePath: filePath,
      url: url,
      method: method,
      headers: headers
    )

      result(true)
    }

    // 1) Register all Flutter plugins (required for Workmanager, notifications, etc.)
    GeneratedPluginRegistrant.register(with: self)

    // 2) Let local notifications show when app is foregrounded
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


