import UIKit
import Flutter
import UserNotifications

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {

  // Flutter method channel used by Dart side (IOSBgUpload.start)
  static var bgChannel: FlutterMethodChannel?
  // Stored completion handler for background URLSession relaunch
  var bgCompletionHandler: (() -> Void)?

  // MARK: - App launch
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Register Flutter plugins first
    GeneratedPluginRegistrant.register(with: self)

    // Create the single background uploader channel
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "background_uploader",
        binaryMessenger: controller.binaryMessenger
      )
      AppDelegate.bgChannel = channel

      channel.setMethodCallHandler { call, result in
        switch call.method {

        case "start":
          // Expecting: { filePath: String, presignedUrl: String, headers?: {..}, method?: "PUT"|"POST" }
          guard
            let args = call.arguments as? [String: Any],
            let filePath   = args["filePath"] as? String,
            let presigned  = args["presignedUrl"] as? String
          else {
            result(FlutterError(code: "bad_args", message: "filePath/presignedUrl missing", details: nil))
            return
          }
          let headers = (args["headers"] as? [String: String]) ?? [:]
          let method  = (args["method"]  as? String) ?? "PUT"

          do {
            try BackgroundUploader.shared.start(
              filePath: filePath,
              presignedUrl: presigned,
              headers: headers,
              method: method
            )
            result(true)
          } catch {
            result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // Allow foreground notifications
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Background URLSession wake (required for background uploads)
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // Reconnect our background URLSession and keep handler to call when tasks finish
    BackgroundUploader.shared.restore(identifier: identifier)
    self.bgCompletionHandler = completionHandler
  }
  
}

// MARK: - Embedded BackgroundUploader (no Xcode target edits needed)

final class BackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

  static let shared = BackgroundUploader()

  // Use one well-known identifier everywhere
  private let kBgSessionId = Bundle.main.bundleIdentifier! + ".bg.upload"

  private lazy var session: URLSession = {
    let cfg = URLSessionConfiguration.background(withIdentifier: kBgSessionId)
    cfg.isDiscretionary = false
    cfg.sessionSendsLaunchEvents = true
    // Be resilient on spotty networks:
    if #available(iOS 11.0, *) {
      cfg.waitsForConnectivity = true
    }
    cfg.allowsCellularAccess = true
    if #available(iOS 13.0, *) {
      cfg.allowsConstrainedNetworkAccess = true   // Low Data Mode OK
      cfg.allowsExpensiveNetworkAccess = true     // 5G/LTE OK
    }
    return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
  }()

  /// Begin a background upload
  func start(filePath: String, presignedUrl: String, headers: [String:String], method: String) throws {
    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw NSError(domain: "BackgroundUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: "file_not_found"])
    }
    guard let url = URL(string: presignedUrl) else {
      throw NSError(domain: "BackgroundUploader", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad_url"])
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

    let task = session.uploadTask(with: req, fromFile: fileURL)

    // stash minimal metadata so we can echo back to Dart on completion
    let meta: [String: Any] = ["filePath": filePath, "url": presignedUrl]
    if let data = try? JSONSerialization.data(withJSONObject: meta),
       let s = String(data: data, encoding: .utf8) {
      task.taskDescription = s
    }

    task.resume()
  }

  /// Recreate the session when iOS relaunches us for background events
  func restore(identifier: String) {
    guard identifier == kBgSessionId else { return }
    let cfg = URLSessionConfiguration.background(withIdentifier: kBgSessionId)
    cfg.isDiscretionary = false
    cfg.sessionSendsLaunchEvents = true
    if #available(iOS 11.0, *) { cfg.waitsForConnectivity = true }
    cfg.allowsCellularAccess = true
    if #available(iOS 13.0, *) {
      cfg.allowsConstrainedNetworkAccess = true
      cfg.allowsExpensiveNetworkAccess = true
    }
    self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
  }

  // MARK: - URLSessionTaskDelegate

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
    let ok = (200...299).contains(status) && (error == nil)

    var meta: [String: Any] = [:]
    if let s = task.taskDescription,
       let data = s.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      meta = obj
    }

    if let e = error {
      NSLog("bg upload error: \(e.localizedDescription), status=\(status), task=\(task.taskIdentifier)")
    } else {
      NSLog("bg upload completed, status=\(status), task=\(task.taskIdentifier)")
    }

    var payload: [String: Any] = [
      "ok": ok,
      "status": status,
      "taskId": task.taskIdentifier
    ]
    meta.forEach { payload[$0.key] = $1 }
    if let e = error { payload["error"] = e.localizedDescription }

    DispatchQueue.main.async {
      AppDelegate.bgChannel?.invokeMethod("bg_upload_completed", arguments: payload)
    }
  }

  // Called when iOS has delivered all pending events for our background session
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async {
      if let app = UIApplication.shared.delegate as? AppDelegate,
         let handler = app.bgCompletionHandler {
        app.bgCompletionHandler = nil
        handler()
      }
    }
  }
}
