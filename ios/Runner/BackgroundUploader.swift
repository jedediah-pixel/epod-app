import Foundation
import UIKit

final class BackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundUploader()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Bundle.main.bundleIdentifier! + ".bg.upload")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        if #available(iOS 13.0, *) {
            cfg.allowsConstrainedNetworkAccess = true
        }
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func start(filePath: String, url: String, method: String, headers: [String:String]) throws {
        let fileUrl = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw NSError(domain: "BackgroundUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: "file_not_found"])
        }
        guard let reqUrl = URL(string: url) else {
            throw NSError(domain: "BackgroundUploader", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad_url"])
        }
        var req = URLRequest(url: reqUrl)
        req.httpMethod = method
        headers.forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }
        let task = session.uploadTask(with: req, fromFile: fileUrl)
        // Attach metadata so we can report back to Dart on completion
        let meta: [String: Any] = [
            "filePath": filePath,
            "url": url
            // add more fields here if you want to show in Discord (e.g., "podNo": podNo)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: []),
        let s = String(data: data, encoding: .utf8) {
            task.taskDescription = s
        }

        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let http = task.response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let ok = (200...299).contains(status) && (error == nil)

        // Parse back the metadata we attached at creation
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

        // Send a callback to Dart so you can run the same Discord notify format there.
        var payload: [String: Any] = [
            "ok": ok,
            "status": status,
            "taskId": task.taskIdentifier,
        ]
        meta.forEach { payload[$0.key] = $1 }  // merge meta into payload
        if let err = error { payload["error"] = err.localizedDescription }

        DispatchQueue.main.async {
            AppDelegate.bgChannel?.invokeMethod("bg_upload_completed", arguments: payload)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    // Called when the system has delivered all pending background events for this URLSession.
    DispatchQueue.main.async {
        if let app = UIApplication.shared.delegate as? AppDelegate,
           let handler = app.bgCompletionHandler {
            app.bgCompletionHandler = nil
            handler()
        }
    }
}


}
