import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    // Store iOS background-session completion handler until URLSession is fully done.
  var bgCompletionHandler: (() -> Void)?

  // Expose the Flutter channel so BackgroundUploader can call into Dart.
  static var bgChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let controller = window?.rootViewController as! FlutterViewController
    let ch = FlutterMethodChannel(name: "bg_upload", binaryMessenger: controller.binaryMessenger)
    AppDelegate.bgChannel = ch

    ch.setMethodCallHandler { call, result in
        if call.method == "start",
          let args = call.arguments as? [String: Any],
          let path = args["filePath"] as? String,
          let url = args["url"] as? String {
            let method = (args["method"] as? String) ?? "PUT"
            let headers = (args["headers"] as? [String:String]) ?? [:]
            do {
                try BackgroundUploader.shared.start(filePath: path, url: url, method: method, headers: headers)
                result(nil)
            } catch {
                result(FlutterError(code: "bg_start_failed", message: error.localizedDescription, details: nil))
            }
        } else {
            result(FlutterMethodNotImplemented)
        }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func application(_ application: UIApplication,
                  handleEventsForBackgroundURLSession identifier: String,
                  completionHandler: @escaping () -> Void) {
    // Store for later; we'll call this after URLSession says all events are delivered.
    self.bgCompletionHandler = completionHandler
    // Make sure the singleton session is created so delegate callbacks are wired.
    _ = BackgroundUploader.shared
  }

}
