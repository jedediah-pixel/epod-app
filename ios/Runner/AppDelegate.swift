import UIKit
import Flutter
import UserNotifications

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {

  private var bgChannel: FlutterMethodChannel?

  // MARK: - App launch

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController

    // MethodChannel for iOS background uploads
    bgChannel = FlutterMethodChannel(
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

      // Hook the uploader's notifier into Flutter
      BackgroundUploader.shared.notify = { [weak self] payload in
        self?.bgChannel?.invokeMethod("bg_upload_completed", arguments: payload)
      }

      BackgroundUploader.shared.startUpload(
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
    BackgroundUploader.shared.restore(identifier: identifier, completionHandler: completionHandler)
  }
}

// MARK: - BackgroundUploader (embedded to avoid Xcode project edits)

final class BackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

  static let shared = BackgroundUploader()

  // Use a stable identifier; keep it unique to your app.
  private let identifier = "com.yourco.hmepod.bg.upload"

  private var session: URLSession!
  private var completionHandler: (() -> Void)?

  /// Called by AppDelegate to send a completion payload to Dart.
  var notify: (([String: Any]) -> Void)?

  override init() {
    super.init()
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.allowsCellularAccess = true
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  /// Recreate the background session after iOS wakes your app and stash the OS completion handler.
  func restore(identifier: String, completionHandler: @escaping () -> Void) {
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.allowsCellularAccess = true
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    self.completionHandler = completionHandler
  }

  /// Start a background PUT upload.
  func startUpload(filePath: String, url: String, method: String, headers: [String:String]) {
    guard let u = URL(string: url) else { return }
    let fileURL = URL(fileURLWithPath: filePath)

    var req = URLRequest(url: u)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let task = session.uploadTask(with: req, fromFile: fileURL)
    task.taskDescription = filePath // so we can report which file completed
    task.resume()
  }

  // MARK: URLSessionTaskDelegate

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    let ok = (error == nil) && (200...299).contains(status)
    let payload: [String: Any] = [
      "ok": ok,
      "status": status,
      "taskId": task.taskIdentifier,
      "filePath": task.taskDescription ?? "",
      "url": task.originalRequest?.url?.absoluteString ?? "",
      "error": error?.localizedDescription as Any
    ]
    notify?(payload)
  }

  /// Called when all events for the background session have been delivered by iOS.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async { [weak self] in
      self?.completionHandler?()
      self?.completionHandler = nil
    }
  }
}
