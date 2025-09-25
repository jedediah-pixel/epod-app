import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

class IOSBgUpload {
  static const _ch = MethodChannel('bg_upload');

  // Broadcasts completion events from iOS background URLSession.
  // Payload shape (Swift builds it):
  // {
  //   "ok": bool,
  //   "status": int,          // HTTP status
  //   "taskId": int,
  //   "filePath": String,     // from meta
  //   "url": String,          // from meta
  //   "error": String?        // if any
  // }
  static final StreamController<Map<String, dynamic>> _completedCtl =
      StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> get onCompleted => _completedCtl.stream;

  // Install a handler as soon as this class is loaded.
  static bool _installed = _installOnce();
  static bool _installOnce() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'bg_upload_completed') {
        final Map<String, dynamic> args =
            Map<String, dynamic>.from(call.arguments as Map);
        _completedCtl.add(args);
      }
    });
    return true;
  }

  /// Returns true if started (iOS), or false on non-iOS platforms.
  static Future<bool> start({
    required String filePath,
    required String presignedUrl,
    Map<String, String>? headers,
    String method = 'PUT',
  }) async {
    if (!Platform.isIOS) return false;
    await _ch.invokeMethod('start', {
      'filePath': filePath,
      'url': presignedUrl,
      'method': method,
      'headers': headers ?? const <String, String>{},
    });
    return true;
  }
}
