
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:math';
import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart'; // for DartPluginRegistrant
import 'package:permission_handler/permission_handler.dart';
import 'dart:ui' as ui;
import 'dart:io' show File, Directory, Platform;
import 'upload_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'ios_bg_upload.dart';


/// WorkManager background entrypoint — must be a TOP-LEVEL function.
@pragma('vm:entry-point')
void uploadCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    await UploadQueue.instance.init();
    await UploadQueue.instance.rescanFromDisk();
        // ===== B) RESTORE SESSION FOR BACKGROUND ISOLATE (ADD THIS) =====
    // Make sure you have:  import 'package:shared_preferences/shared_preferences.dart';
    final prefs   = await SharedPreferences.getInstance();
    final driver  = prefs.getString('session.driverId');
    final day     = prefs.getString('session.day');
    final token   = prefs.getString('session.token');

    if (driver != null && day != null && token != null) {
      // If you already have a setter on your queue, use it:
      UploadQueue.instance.setSession(
        driverId: driver,
        day: day,
        token: token,
      );
      debugPrint('WM[barcode_uploader]: restored session driver=$driver day=$day');
    } else {
      debugPrint('WM[barcode_uploader]: no saved session -> may hit no_session_for_day');
    }
    // ===== END B) =====
    try {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/upload_queue');
      final list = await dir.list(recursive: true).toList();
      debugPrint('WM[barcode_uploader]: queue dir=${dir.path} files=${list.length}');
      for (final e in list.take(10)) {
        debugPrint('WM[barcode_uploader]: qfile ${e.path}');
      }
    } catch (e) {
      debugPrint('WM[barcode_uploader]: queue list error $e');
    }

    debugPrint(
      'WM[barcode_uploader]: dispatcher start task=$task data=$inputData '
      'hasJobs=${UploadQueue.instance.hasJobs} count=${UploadQueue.instance.jobCount}'
    );
    debugPrint('DEBUG4 WM hasJobs=${UploadQueue.instance.hasJobs} count=${UploadQueue.instance.jobCount}');

    final ok = await UploadQueue.instance.drain();

    await UploadNotifications.update(
      hasJobs: UploadQueue.instance.hasJobs,
      jobCount: UploadQueue.instance.jobCount,
    );

    debugPrint(
      'WM[barcode_uploader]: dispatcher done (success=$ok remaining=${UploadQueue.instance.jobCount})'
    );
    return ok; // <- this is the bool you got from drain()
  });
}

Future<void> _requestAndroidPostNotifications() async {
  if (Platform.isAndroid) {
    // On Android 13+ this will show the system permission prompt.
    // On older Android versions it's a no-op.
    await Permission.notification.request();
  }
}

const _bucketBase = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com';
// ===== Admin API base =====
const String kApiBase = 'https://s3-upload-api-trvm.onrender.com';
// Base URL (NO trailing slash). Use your bucket or CDN domain.
const kS3Base = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com';

// ===== SharedPreferences keys =====
const String kSpAdminToken = 'adminToken';
const String kSpAdminTokenExp = 'adminTokenExp'; // optional: epoch ms
// Per-driver session storage (QR unlock) -> sess.token.<driverId>, sess.day.<driverId>
const String kSpSessTokenPrefix = 'sess.token.';
const String kSpSessDayPrefix   = 'sess.day.';

// ---- S3 Daily List Helpers ----
const _listsBase = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com/lists/daily';

// was: bundles/HM-7d.json
const String _weeklyBundleUrl =
    'https://hm-epod.s3.ap-southeast-1.amazonaws.com/lists/HM-latest.json';

String _fmt(DateTime d, String pattern) {
  String two(int n) => n.toString().padLeft(2, '0');
  String yyyy = d.year.toString();
  String yy = d.year.toString().substring(2);
  String MM = two(d.month);
  String dd = two(d.day);
  return pattern
      .replaceAll('yyyy', yyyy)
      .replaceAll('yy', yy)
      .replaceAll('MM', MM)
      .replaceAll('dd', dd);
}

List<Uri> _candidateDailyListUrls(DateTime when) {
  final v = DateTime.now().millisecondsSinceEpoch;
  final c1 = Uri.parse('$_listsBase/HM ${_fmt(when, 'dd-MM-yy')}.json?v=$v');
  final c2 = Uri.parse('$_listsBase/HM ${_fmt(when, 'dd-MM-yyyy')}.json?v=$v');
  return [c1, c2];
}

bool _rowMatchesUser(Map<String, dynamic> m, String username) {
  final u = username.trim().toLowerCase();
  final driver = (m['Driver'] ?? m['driver'] ?? m['Assigned To'] ?? m['assigned_to'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  return driver == u || driver.contains(u);
}

// Shared: load the same 7-day bundle the Driver uses
Future<List<dynamic>> loadWeekRowsFromS3() async {
  final uri = Uri.parse('$_weeklyBundleUrl?v=${DateTime.now().millisecondsSinceEpoch}');
  try {
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      final root = jsonDecode(utf8.decode(res.bodyBytes));
      if (root is List) return root;
      if (root is Map && root['bundle'] is List) return (root['bundle'] as List).cast<dynamic>();
    }
  } catch (_) {}

  // Fallback: fetch last 7 daily files if pointer isn’t available
  final now = _todayMY();
  final days = List.generate(7, (i) {
    final d = now.subtract(Duration(days: i));
    return DateTime(d.year, d.month, d.day);
  });

  final all = <dynamic>[];
  for (final day in days) {
    List<dynamic>? rows;
    for (final url in _candidateDailyListUrls(day)) {
      try {
        final r = await http.get(url);
        if (r.statusCode == 200) {
          rows = jsonDecode(utf8.decode(r.bodyBytes)) as List<dynamic>;
          break;
        }
      } catch (_) {}
    }
    if (rows != null) all.addAll(rows);
  }
  return all;
}

DateTime _todayMY() {
  // Normalize to Asia/Kuala_Lumpur (UTC+08:00), no DST
  final nowUtc = DateTime.now().toUtc();
  final my = nowUtc.add(const Duration(hours: 8));
  return DateTime(my.year, my.month, my.day);
}
String _todayYMD() => DateFormat('yyyy-MM-dd').format(_todayMY());


// dd/MM/yy or dd/MM/yyyy  ->  yyyy-MM-dd
String _ymdFromRdd(String r) {
  r = (r ?? '').toString().trim();

  // dd/MM/yy or dd/MM/yyyy
  for (final fmt in ['dd/MM/yy', 'dd/MM/yyyy']) {
    try {
      final d = DateFormat(fmt).parse(r);
      return DateFormat('yyyy-MM-dd').format(d);
    } catch (_) {}
  }

  // yyyy-MM-dd or yyyy-MM-dd HH:mm:ss
  for (final fmt in ['yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss']) {
    try {
      final d = DateFormat(fmt).parse(r);
      return DateFormat('yyyy-MM-dd').format(d);
    } catch (_) {}
  }

  // ISO fallback
  try {
    final d = DateTime.parse(r);
    return DateFormat('yyyy-MM-dd').format(d);
  } catch (_) {}

  // Last resort
  return _todayYMD();
}

String? _ymdFromRddOrNull(String r) {
  r = (r ?? '').toString().trim();

  for (final fmt in ['dd/MM/yy', 'dd/MM/yyyy']) {
    try {
      final d = DateFormat(fmt).parse(r);
      return DateFormat('yyyy-MM-dd').format(d);
    } catch (_) {}
  }
  for (final fmt in ['yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss']) {
    try {
      final d = DateFormat(fmt).parse(r);
      return DateFormat('yyyy-MM-dd').format(d);
    } catch (_) {}
  }
  try {
    final d = DateTime.parse(r);
    return DateFormat('yyyy-MM-dd').format(d);
  } catch (_) {}

  return null; // <-- do not default to today
}


String _displayDay(String raw) {
  raw = (raw ?? '').toString().trim();

  // Try common formats you might receive
  for (final fmt in ['dd/MM/yy', 'dd/MM/yyyy', 'yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss']) {
    try {
      final d = DateFormat(fmt).parse(raw);
      // <<< choose your preferred display format here >>>
      return DateFormat('dd/MM/yyyy').format(d); // or 'yyyy-MM-dd'
    } catch (_) {}
  }

  // ISO fallback
  try {
    final d = DateTime.parse(raw);
    return DateFormat('dd/MM/yyyy').format(d);
  } catch (_) {}

  // If we can’t parse, just show the original string
  return raw;
}

// ============ Background upload queue ============

class UploadJob {
  final String id;                 // unique id
  final String username;
  final String podNo;
  final String rddDate;            // dd/MM/yyyy (as shown in UI)
  final bool isRejected;
  final String? sessionToken;      // driver/day JWT (if present)
  final String? sessionDay;        // YYYY-MM-DD (when JWT is valid)
  final List<String> imagePaths;   // absolute local paths (we copy them)

  int attempts;
  UploadJob({
    required this.id,
    required this.username,
    required this.podNo,
    required this.rddDate,
    required this.isRejected,
    required this.sessionToken,
    required this.sessionDay,
    required this.imagePaths,
    this.attempts = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'podNo': podNo,
    'rddDate': rddDate,
    'isRejected': isRejected,
    'sessionToken': sessionToken,
    'sessionDay': sessionDay,
    'imagePaths': imagePaths,
    'attempts': attempts,
  };

  static UploadJob fromJson(Map<String, dynamic> m) => UploadJob(
    id: m['id'],
    username: m['username'],
    podNo: m['podNo'],
    rddDate: m['rddDate'],
    isRejected: m['isRejected'] == true,
    sessionToken: m['sessionToken'],
    sessionDay: m['sessionDay'],
    imagePaths: (m['imagePaths'] as List).map((e) => e.toString()).toList(),
    attempts: (m['attempts'] ?? 0) as int,
  );
}

extension StringCap on String {
  String capitalizeFirst() =>
      isEmpty ? this : this[0].toUpperCase() + substring(1);
}

class QueueEvent {
  final String jobId;
  final String podNo;
  final bool success;
  final List<String> urls;
  QueueEvent(this.jobId, this.podNo, this.success, this.urls);
}

class PermanentFail implements Exception {
  final String reason;
  PermanentFail(this.reason);
  @override
  String toString() => 'PermanentFail: $reason';
}

class UploadQueue {

  String? _sessionDriverId;
  String? _sessionDay;
  String? _sessionToken;

  void setSession({
    required String token,
    required String day,
    required String driverId,
  }) {
    _sessionToken   = token;
    _sessionDay     = day;
    _sessionDriverId= driverId;
  }

  // Expose the internal pump as a public method for WorkManager isolate.
  static final UploadQueue instance = UploadQueue._internal();
  UploadQueue._internal();
  factory UploadQueue() => instance;

  Future<void> rememberSession({
    required String driverId,
    required String day,          // yyyy-MM-dd
    required String token,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // Save under both keys to be safe with existing _auth() implementations
    await prefs.setString('session.$day', token);
    await prefs.setString('session.$driverId.$day', token);
  }


  Future<bool> drain() async {
    // ensure disk state is loaded when called from WM isolate
    await runHeadlessUntilEmpty();
    // tell WorkManager the task finished OK
    return true;

    // (Optional alternative if you want WM to retry while there are still jobs)
    // return !hasJobs;
  }

  static const int kMaxAttempts = 12; // hard cap on retries

  // Build a dedupe key (same user+day+POD = same job)
  String _jobKey(UploadJob j) {
    final day = _ymdFromRdd(j.rddDate);   // always the POD’s actual day
    return '${j.username.toLowerCase()}|$day|${j.podNo}';
  }

  // Compare two YYYY-MM-DD dates as day counts (no timezones)
  int _daysBetweenYmd(String a, String b) {
    DateTime p(String s) => DateFormat('yyyy-MM-dd').parse(s);
    final da = DateTime(p(a).year, p(a).month, p(a).day);
    final db = DateTime(p(b).year, p(b).month, p(b).day);
    return da.difference(db).inDays;
  }

  // Optional: re-read jobs from disk and try again
  Future<void> rescanFromDisk() async {
    await _loadJobsFromDisk();
    if (_jobs.isNotEmpty) _start();
    UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);
  }

  UploadQueue._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(minutes: 10),
    sendTimeout: const Duration(minutes: 10),
  ));

  final _events = StreamController<QueueEvent>.broadcast();
  Stream<QueueEvent> get events => _events.stream;

  bool _running = false;
  Directory? _root;          // <app-docs>/upload_queue
  final _jobs = <UploadJob>[];
  bool get hasJobs => _jobs.isNotEmpty;
  int  get jobCount => _jobs.length; // optional, handy for debugging
  StreamSubscription? _connSub;

  Future<void> init() async {
    if (_root == null) {
      final docs = await getApplicationDocumentsDirectory();
      _root = Directory('${docs.path}/upload_queue');
      if (!await _root!.exists()) await _root!.create(recursive: true);
      await _loadJobsFromDisk();
      _connSub = Connectivity().onConnectivityChanged.listen((_) {
        if (_jobs.isNotEmpty) _start();
      });
    }
    if (_jobs.isNotEmpty) _start();
  }

  Future<void> dispose() async {
    await _connSub?.cancel();
    await _events.close();
  }

  Future<void> enqueue(UploadJob job) async {
    // De-dup: if a job exists for the same (user, day, POD), replace it.
    final _k = _jobKey(job);
    final i = _jobs.indexWhere((x) => _jobKey(x) == _k);
    if (i >= 0) {
      // remove old job folder so we don't leave stale files
      final old = _jobs[i];
      final oldDir = Directory('${_root!.path}/${old.id}');
      if (await oldDir.exists()) {
        try { await oldDir.delete(recursive: true); } catch (_) {}
      }
      _jobs.removeAt(i);
    }

    final dir = Directory('${_root!.path}/${job.id}');
    if (!await dir.exists()) await dir.create(recursive: true);

    final copied = <String>[];
    for (var i = 0; i < job.imagePaths.length; i++) {
      final src = File(job.imagePaths[i]);
      final dst = File('${dir.path}/${job.podNo}_${i + 1}.jpg');
      await dst.writeAsBytes(await src.readAsBytes(), flush: true);
      copied.add(dst.path);
    }

    final f = File('${dir.path}/job.json');
    final save = job.toJson()..['imagePaths'] = copied;
    await f.writeAsString(jsonEncode(save), flush: true);

    _jobs.add(UploadJob.fromJson(save));
    UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);

      // Schedule/keep a single "drain the queue" job on Android
      if (Platform.isAndroid) {
        debugPrint('WM[barcode_uploader]: registering drain_uploads (reason=new_job_enqueued)');
        await Workmanager().registerOneOffTask(
          'drain-upload-queue',
          'drain_uploads',
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: true,
            requiresStorageNotLow: true,
          ),
          existingWorkPolicy: ExistingWorkPolicy.keep,
          backoffPolicy: BackoffPolicy.exponential,
          backoffPolicyDelay: const Duration(seconds: 30),
          initialDelay: const Duration(seconds: 1),
          inputData: {'reason': 'new_job_enqueued'},
        );
      } else {
        _start();// foreground drain on non-Android (e.g., iOS)
      }

  }

  Future<void> _loadJobsFromDisk() async {
    _jobs.clear();
    if (_root == null) return;
    final dirs = _root!.listSync().whereType<Directory>();
    for (final d in dirs) {
      final f = File('${d.path}/job.json');
      if (await f.exists()) {
        try {
          _jobs.add(UploadJob.fromJson(jsonDecode(await f.readAsString())));
        } catch (_) {/* skip bad job */}
      }
    }
    // after finishing the for-loop:
    debugPrint('DEBUG3 loadJobsFromDisk: count=${_jobs.length}');
    for (final j in _jobs) {
      debugPrint('DEBUG3 job: id=${j.id} pod=${j.podNo} imgs=${j.imagePaths.length}');
    }

  }

/// Delete any queued *copies* for a given driver+POD (used after we see a manifest).
Future<int> deleteQueueCopiesForPod({
  required String username,
  required String podNo,
}) async {
  if (_root == null) return 0;
  int removed = 0;
  final dirs = _root!.listSync().whereType<Directory>();
  for (final d in dirs) {
    final f = File('${d.path}/job.json');
    if (!await f.exists()) continue;
    try {
      final j = UploadJob.fromJson(jsonDecode(await f.readAsString()));
      if (j.username.toLowerCase() == username.toLowerCase() &&
          j.podNo == podNo) {
        await d.delete(recursive: true);
        removed++;
      }
    } catch (_) {/* ignore bad job */}
  }
  return removed;
}


  void _start() {
    if (Platform.isAndroid) {
    // On Android we let WorkManager own the drain to avoid races.
      return;
    }
    if (_running) return;
    _running = true;
    _pump();
  }

  Future<void> _pump() async {
    while (_jobs.isNotEmpty) {
      final job = _jobs.first;

      // Hard cap
      if (job.attempts >= kMaxAttempts) {
        _events.add(QueueEvent(job.id, job.podNo, false, const []));
        await _deleteJobFiles(job);          // drop the stuck job
        _jobs.removeAt(0);
        UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);
        continue;                            // move to next job
      }

      bool ok = false;
      bool permanent = false;

      try {
        ok = await _process(job);               // success = true
      } on PermanentFail catch (e) {
        permanent = true;
        debugPrint('Upload permanent fail: ${e.reason}');
      } catch (e, st) {
        // transient or unexpected — fall through to retry path
        debugPrint('Upload transient/unknown error: $e\n$st');
        ok = false;
      }

      if (ok) {
        _events.add(QueueEvent(job.id, job.podNo, true, await _deriveUrls(job)));
        await _deleteJobFiles(job);
        _jobs.removeAt(0);
        UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);
        continue;
      }

      if (permanent) {
        // stop retrying this job
        _events.add(QueueEvent(job.id, job.podNo, false, const []));
        await _deleteJobFiles(job);
        _jobs.removeAt(0);
        UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);
        continue;
      }

      // transient: backoff (but cap attempts)
      job.attempts += 1;
      if (job.attempts >= kMaxAttempts) {
        _events.add(QueueEvent(job.id, job.podNo, false, const []));
        await _saveJob(job);
        await _deleteJobFiles(job);
        _jobs.removeAt(0);
        UploadNotifications.update(hasJobs: hasJobs, jobCount: jobCount);
        continue;
      }

      await _saveJob(job);
      await Future.delayed(_delay(job.attempts));
    }

    _running = false;
  }

  /// Run the queue to completion from a background isolate (WorkManager).
  Future<void> runHeadlessUntilEmpty() async {
    // Ensure the upload root and jobs list are ready in this isolate
    if (_root == null) {
      final docs = await getApplicationDocumentsDirectory();
      _root = Directory('${docs.path}/upload_queue');
      if (!await _root!.exists()) {
        await _root!.create(recursive: true);
      }
      await _loadJobsFromDisk();
    } else if (_jobs.isEmpty) {
      // If we already know the root but this isolate has an empty list, re-load.
      await _loadJobsFromDisk();
    }

    if (_jobs.isEmpty) return;

    // If another pump is somehow running, wait briefly (defensive)
    if (_running) {
      while (_running) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (_jobs.isEmpty) return;
    }

    _running = true;
    await _pump();  // _pump() will loop until _jobs is empty and then set _running=false
  }

  Duration _delay(int attempts) {
    final steps = [2, 8, 30, 60, 120];
    return Duration(seconds: steps[min(attempts, steps.length) - 1]);
  }

Future<bool> _process(UploadJob j) async {
  debugPrint('DEBUG5 process: id=${j.id} pod=${j.podNo} '
      'day=${_ymdFromRdd(j.rddDate)} imgs=${j.imagePaths.length}');
  for (final p in j.imagePaths) {
    debugPrint('DEBUG5 imgPath=$p exists=${await File(p).exists()}');
  }

  try {
    final day = _ymdFromRdd(j.rddDate); // POD’s actual day
    // Use job’s JWT if present; else fallback to a saved JWT for this driver/day
    String? jwtToken = j.sessionToken;
    if (jwtToken == null || jwtToken.isEmpty) {
      final sp = await SharedPreferences.getInstance();
      final u = (j.username ?? '').toLowerCase();
      // Try a per-day token if you ever save it, then a general latest token
      jwtToken = sp.getString('sess.token.$u.$day')
              ?? sp.getString('sess.token.$u');
    }

    debugPrint('WM[barcode_uploader]: job=${j.id} pod=${j.podNo} images=${j.imagePaths.length} day=$day');

    // ---- Age guard: today .. 6 days old (no future) ----
    final today = _todayYMD();
    final diff = _daysBetweenYmd(day, today); // positive if 'day' after today
    if (diff < -6 || diff > 0) {
      throw PermanentFail('day_out_of_window:$day');
    }

    // ---- JWT fallback: if job has no token, try per-day cache (then legacy) ----

    if (jwtToken == null) {
      final sp = await SharedPreferences.getInstance();
      final u = (j.username ?? '').toLowerCase();
      jwtToken = sp.getString('sess.token.$u.$day') ?? sp.getString('sess.token.$u');
      if (jwtToken != null) {
        debugPrint('WM[barcode_uploader]: using cached JWT for $u on $today');
      }
    }

    Map<String, String> _auth(String contentType, String key) {
      final t = jwtToken;
      if (t == null || t.isEmpty) {
        throw PermanentFail('no_session_token');
      }
      return {
        'Authorization': 'Bearer $t',
        'Content-Type': contentType,
        'x-api-key': key,
        // No 'x-session-day' header needed if your backend validates the JWT
      };
    }

    bool _isPermanentSign(int code, String body) {
      if (code == 400 || code == 401 || code == 403 || code == 404) return true;
      final b = body.toLowerCase();
      return b.contains('too_old_or_future') ||
             b.contains('key_not_allowed') ||
             b.contains('driver_or_day_mismatch') ||
             b.contains('session_required_for_today') ||
             b.contains('no_session_for_day');
    }

    bool _isPermanentPut(int code) => false; // all PUT failures -> retryable

    final urls = <String>[];

    // ---- Upload each image ----
    for (var i = 0; i < j.imagePaths.length; i++) {
      final key = 'pods/$day/${(j.username ?? '').toLowerCase()}/${j.podNo}_${i + 1}.jpg';

      // 1) sign (get presigned PUT URL)
      debugPrint('WM[barcode_uploader]: AUTH tokenLen=${jwtToken?.length ?? 0} key=$key');
      final signRes = await http.post(
        Uri.parse('$kApiBase/sign'),
        headers: _auth('application/json', key),
        body: jsonEncode({'filename': key, 'contentType': 'image/jpeg'}),
      );

      final bodyStr = signRes.body;
      final bodyLog = bodyStr.length > 300 ? '${bodyStr.substring(0, 300)}…' : bodyStr;
      debugPrint('WM[barcode_uploader]: sign ${signRes.statusCode} job=${j.id} fileIdx=${i + 1} body=$bodyLog');

      if (signRes.statusCode != 200) {
        if (_isPermanentSign(signRes.statusCode, bodyStr)) {
          throw PermanentFail('sign:${signRes.statusCode}:${bodyLog}');
        }
        return false; // transient -> WM retry
      }

      final signed = (jsonDecode(signRes.body)['url'] as String);

      // 2) PUT to S3
      final imgPath = j.imagePaths[i];
      final imgFile = File(imgPath);
      if (!await imgFile.exists()) {
        debugPrint('WM[barcode_uploader]: missing image; skip job=${j.id} path=$imgPath');
        await rescanFromDisk();
        throw Exception('image missing');
      }

      debugPrint('WM[barcode_uploader]: PUT start job=${j.id} file=$imgPath');
      final _iosStarted = await IOSBgUpload.start(
        filePath: imgPath,
        presignedUrl: signed,
        headers: {'Content-Type': 'image/jpeg'},
        method: 'PUT',
      );
      if (_iosStarted) {
        debugPrint('WM[barcode_uploader]: iOS background PUT started for $imgPath');
        final uri = Uri.parse(signed);
        var segs = List.of(uri.pathSegments);
        if (segs.isNotEmpty && segs.first == 'hm-epod') segs = segs.sublist(1);
        urls.add('$_bucketBase/${segs.join('/')}');
        continue;
      }

      final put = await _dio.put(
        signed,
        data: await imgFile.readAsBytes(),
        options: Options(
          headers: {'Content-Type': 'image/jpeg'},
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
      debugPrint('WM[barcode_uploader]: PUT done job=${j.id} status=${put.statusCode}');
      final putCode = put.statusCode ?? 0;
      if (putCode != 200 && putCode != 201 && putCode != 204) {
        if (_isPermanentPut(putCode)) throw PermanentFail('put:$putCode');
        return false;
      }

      // 3) derive public URL
      final uri = Uri.parse(signed);
      var segs = List.of(uri.pathSegments);
      if (segs.isNotEmpty && segs.first == 'hm-epod') segs = segs.sublist(1);
      urls.add('$_bucketBase/${segs.join('/')}');
    }

    // ---- Manifest (status + urls) ----
    final manifestKey = 'pods/$day/${(j.username ?? '').toLowerCase()}/${j.podNo}_meta.json';
    final manifestSign = await http.post(
      Uri.parse('$kApiBase/sign'),
      headers: _auth('application/json', manifestKey),
      body: jsonEncode({'filename': manifestKey, 'contentType': 'application/json'}),
    );
    final mBodyStr = manifestSign.body;
    final mBodyLog = mBodyStr.length > 300 ? '${mBodyStr.substring(0, 300)}…' : mBodyStr;
    debugPrint('WM[barcode_uploader]: sign(manifest) ${manifestSign.statusCode} job=${j.id} body=$mBodyLog');

    if (manifestSign.statusCode != 200) {
      if (_isPermanentSign(manifestSign.statusCode, mBodyStr)) {
        throw PermanentFail('sign_manifest:${manifestSign.statusCode}:${mBodyLog}');
      }
      return false;
    }

    final manifestUrl = (jsonDecode(manifestSign.body)['url'] as String);
    final status = j.isRejected ? 'rejected' : 'delivered';

    final putManifest = await _dio.put(
      manifestUrl,
      data: utf8.encode(jsonEncode({
        'podNo': j.podNo,
        'status': status,
        'urls': urls,
        'updatedBy': (j.username ?? '').toLowerCase(),
        'updatedAt': DateTime.now().toIso8601String(),
      })),
      options: Options(headers: {'Content-Type': 'application/json'}),
    );

    final manCode = putManifest.statusCode ?? 0;
    debugPrint('WM[barcode_uploader]: manifest PUT status=$manCode for job=${j.id}');
    if (manCode != 200 && manCode != 201 && manCode != 204) {
      if (_isPermanentPut(manCode)) throw PermanentFail('put_manifest:$manCode');
      return false;
    }

    // ---- Notify AFTER manifest succeeds ----
    try {
      await http.post(
        Uri.parse('$kApiBase/ack'),
        headers: _auth('application/json', 'pods/$day/${(j.username ?? '').toLowerCase()}/${j.podNo}_1.jpg')
          ..addAll({'x-driver': (j.username ?? '').toLowerCase()}),
        body: jsonEncode({'podNo': j.podNo, 'day': day, 'username': (j.username ?? '').toLowerCase()}),
      );
    } catch (_) {}

    try {
      final anyKey = 'pods/$day/${(j.username ?? '').toLowerCase()}/${j.podNo}_1.jpg';
      await http.post(
        Uri.parse('$kApiBase/notify'),
        headers: _auth('application/json', anyKey),
        body: jsonEncode({
          'content': '📦 DO: ${j.podNo}\n${j.isRejected ? '❌ Rejected' : '✅ Delivered'}\n🚚 ${(j.username ?? '').toLowerCase()}\n📅 ${j.rddDate}',
          'imageUrls': urls,
        }),
      );
    } catch (_) {}

    return true;
  } catch (e, st) {
    debugPrint('UploadQueue _process error: $e\n$st');
    if (e is PermanentFail) rethrow;
    return false;
  }
}


  Future<void> _saveJob(UploadJob j) async {
    final dir = Directory('${_root!.path}/${j.id}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final f = File('${dir.path}/job.json');
    await f.writeAsString(jsonEncode(j.toJson()), flush: true);
  }

  Future<void> _deleteJobFiles(UploadJob j) async {
    final dir = Directory('${_root!.path}/${j.id}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<List<String>> _deriveUrls(UploadJob j) async {
    final day = _ymdFromRdd(j.rddDate);
    return List.generate(
      j.imagePaths.length,
      (i) => '$_bucketBase/pods/$day/${j.username}/${j.podNo}_${i + 1}.jpg',
    );
  }
}

enum PodStatus { delivered, rejected, pending }

class UploadResult {
  final List<String> urls;
  final PodStatus status;
  final List<File>? localFiles; // newly captured files
  UploadResult(this.urls, this.status, {this.localFiles});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _requestAndroidPostNotifications();

  // 1) Init WorkManager FIRST (must happen before any registerOneOffTask)
  Workmanager().initialize(uploadCallbackDispatcher, isInDebugMode: kDebugMode);

  // 2) (If you added the helper) init the notification channel
  await UploadNotifications.init();

  // 3) Load queue once and reflect status
  await UploadQueue.instance.init();
  await UploadQueue.instance.rescanFromDisk();

  //   Keep the sticky "Uploading POD…" notif in sync (safe to omit if you didn't add it yet)
  await UploadNotifications.update(
    hasJobs: UploadQueue.instance.hasJobs,
    jobCount: UploadQueue.instance.jobCount,
  );

// --- iOS: listen for background URLSession completions and run finalize + Discord ---
if (Platform.isIOS) {
  IOSBgUpload.onCompleted.listen((e) async {
    // Payload from iOS (BackgroundUploader.swift):
    // { ok: bool, status: int, taskId: int, filePath: String, url: String, error?: String }
    final ok = (e['ok'] as bool?) ?? false;
    final status = e['status']?.toString() ?? '?'; // keep as String (your preference)
    final filePath = (e['filePath'] as String?) ?? '';
    final baseName = filePath.split('/').isNotEmpty ? filePath.split('/').last : filePath;

    try {
      // ===== REQUIRED: call your existing "finalize + Discord" helper here =====
      // UNCOMMENT the next line and replace the function name/params with yours.
      // await finalizeAndNotifyDiscord(
      //   filePath: filePath,
      //   httpStatus: int.tryParse(status) ?? -1,
      // );

      // ===== OPTIONAL: extra short note like "<filename> upload complete (iOS)" =====
      // UNCOMMENT this block if your helper supports an extra message field.
      // await finalizeAndNotifyDiscord(
      //   filePath: filePath,
      //   httpStatus: int.tryParse(status) ?? -1,
      //   extraMessage: '$baseName upload complete (iOS)',
      // );

      // If you haven't wired the helper yet, at least keep a log:
      // debugPrint('[iOS bg] completed: ok=$ok status=$status file=$filePath');
    } catch (err) {
      // 🔧 Keep this log uncommented for visibility when something goes wrong.
      debugPrint('iOS bg finalize/notify error: $err (file=$filePath, status=$status)');
    }
  });
}


  // 4) If leftovers exist at cold start, kick the drain immediately
  if (Platform.isAndroid && UploadQueue.instance.hasJobs) {
    await Workmanager().registerOneOffTask(
      'drain-upload-queue',
      'drain_uploads',
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
        requiresStorageNotLow: true,
      ),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      inputData: {'reason': 'app_launch_with_leftovers'},
    );
  }

  // 5) Launch UI
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

@override
Widget build(BuildContext context) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        foregroundColor: Colors.black, // icons & title
        titleTextStyle: TextStyle(
          color: Colors.black,          // <-- make title text black
          fontSize: 30,
          fontWeight: FontWeight.w700,
        ),
        toolbarHeight: 64,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        labelStyle: TextStyle(fontSize: 18),
        floatingLabelStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        contentPadding: EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        border: OutlineInputBorder(),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          minimumSize: MaterialStatePropertyAll(Size(0, 40)),
          textStyle: MaterialStatePropertyAll(
            TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 16),
        bodyLarge: TextStyle(fontSize: 18),
      ),
    ),

    // 👇 keep this
    initialRoute: '/',

    // 👇 ADD THIS ROUTES MAP
    routes: {
      '/': (context) => const BarcodeUploaderApp(),
      '/admin/login': (context) => const AdminLoginPage(),
      '/admin': (context) => const AdminHomePage(),
      '/admin/list': (context) {
        final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
        return AdminListPage(
          driverId: args['driverId'] as String,
          displayName: args['displayName'] as String,
        );
      },
    },
  );
}
}

final Map<String, String> driverCredentials = {
  'bala': 'bala123',
  'sami': 'sami123',
  'alex': 'john123',
  'david': 'david586',
  'alexraj': 'alexraj834',
  'keeran': 'keeran378',
  'yong': 'yong039',
  'joon': 'joon495',
  'keong': 'keong876',
  'maha': 'maha225',
  'pavi': 'pavi877',
  'ganesh': 'ganesh920',
  'sri': 'sri847',
};

class AdminLoginPage extends StatefulWidget {
const AdminLoginPage({super.key});
@override
State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
final _pwd = TextEditingController();
bool _loading = false;
String? _err;

@override
void dispose() {
_pwd.dispose();
super.dispose();
}

Future<void> _submit() async {
setState(() { _loading = true; _err = null; });
try {
final api = AdminApi();
final token = await api.login(_pwd.text.trim());
final sp = await SharedPreferences.getInstance();
await sp.setString(kSpAdminToken, token);
// Optionally store an expiry if you decode it; not required for MVP
if (!mounted) return;
// Navigate to Admin Home (driver picker)
Navigator.of(context).pushReplacementNamed('/admin');
} catch (e) {
setState(() { _err = e.toString(); });
} finally {
setState(() { _loading = false; });
}
}

@override
Widget build(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      centerTitle: true,
      title: const Text('Admin Login'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          } else {
            // If this page was opened with pushReplacementNamed (no back stack),
            // send them to the Driver screen.
            Navigator.of(context).pushReplacementNamed('/');
            // Or, to fully reset the stack:
            // Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
          }
        },
      ),
    ),

    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _pwd,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    label: Center(child: Text('Admin Password', style: TextStyle(fontSize: 15))),
                    floatingLabelAlignment: FloatingLabelAlignment.center,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 300,
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Login'),
                ),
              ),
              if (_err != null) ...[
                const SizedBox(height: 12),
                Text(_err!, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}



}

class LoginPage extends StatefulWidget {
  final void Function(String username) onLoginSuccess;
  const LoginPage({super.key, required this.onLoginSuccess});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _error;

  void _login() {
    final username = _usernameController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (driverCredentials[username] == password) {
      widget.onLoginSuccess(username);
    } else {
      setState(() {
        _error = 'Invalid username or password';
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Driver Login'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _usernameController,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    label: Center(child: Text('Username', style: TextStyle(fontSize: 15))),
                    floatingLabelAlignment: FloatingLabelAlignment.center,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    label: Center(child: Text('Password', style: TextStyle(fontSize: 15))),
                    floatingLabelAlignment: FloatingLabelAlignment.center,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 300,
                height: 48,
                child: ElevatedButton(
                  onPressed: _login,
                  child: const Text('Login'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pushNamed('/admin/login'),
                style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 16), // same size as the button label
              ),
                child: const Text('Admin Login'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

}

class AdminHomePage extends StatefulWidget {
const AdminHomePage({super.key});
@override
State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
String? _token;
List<Map<String, dynamic>> _drivers = [];

Map<String, bool> _approvedToday = {};
bool _loading = true;
String? _err;
// --- Admin scanner state ---
bool _showAdminScanner = false;
final MobileScannerController _adminScanCtrl = MobileScannerController();
bool _adminScanBusy = false;

// ---- Global (7-day) scan index ----
bool _gReady = false;
DateTime? _gBuiltAt;
final List<Map<String, dynamic>> _gFull = [];
final Map<String, List<Map<String, dynamic>>> _g9 = {}; // last 9 digits -> rows
final Map<String, List<Map<String, dynamic>>> _g6 = {}; // last 6 digits -> rows

String _driverIdFromRowOrUnknown(Map<String, dynamic> row) {
  final blankish = {'', '-', 'unassigned', 'unknown', 'n/a', 'na', 'none'};
  for (final k in const [
    'driverId','Driver','driver','Assigned Driver','assigned_driver','Username'
  ]) {
    final v = (row[k] ?? '').toString().trim();
    if (v.isNotEmpty && !blankish.contains(v.toLowerCase())) return v;
  }
  return 'unknown';
}

Future<void> _openPodDetail({
  required String day,
  required String driverId,
  required Map<String, dynamic> row,
}) async {
  if (_token == null || _token!.isEmpty) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not logged in as admin')));
    }
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => AdminPodDetailPage(
        adminToken: _token!,
        day: day,
        driverId: driverId,
        row: row,
      ),
    ),
  );
}


Future<void> _openGlobalSearch() async {
  // Make sure the index is ready
  if (!_gReady && mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preparing 7-day index…')),
    );
  }
  try {
    await _ensureGlobalIndex();
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not build index: $e')),
      );
    }
    return;
  }

  final result = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final qCtrl = TextEditingController();
      List<Map<String, dynamic>> hits = const [];
      bool searching = false;

      List<Map<String, dynamic>> _runSearch(String query) {
        final q = query.trim();
        if (q.isEmpty) return const [];

        // Try by digits (POD suffix) first
        final digits = q.replaceAll(RegExp(r'\D'), '');
        List<Map<String, dynamic>> candidates = const [];

        if (digits.length >= 9) {
          final k9 = digits.substring(digits.length - 9);
          candidates = List<Map<String, dynamic>>.from(_g9[k9] ?? const []);
        } else if (digits.length >= 6) {
          final k6 = digits.substring(digits.length - 6);
          candidates = List<Map<String, dynamic>>.from(_g6[k6] ?? const []);
        } else if (digits.length >= 4) {
          // 4–5 digits: light linear filter
          candidates = _gFull.where((row) {
            final pod = _podIdFromRow(row);
            return _podMatchesScan(pod, digits);
          }).toList();
        }

        // If there were no digits matches AND user typed letters,
        // fall back to Customer substring search.
        if (candidates.isEmpty && digits.isEmpty && q.length >= 2) {
          final qLower = q.toLowerCase();
          candidates = _gFull.where((row) {
            final cust = _customerFromRow(row).toLowerCase();
            return cust.contains(qLower);
          }).toList();
        }

        // Map to the shape the caller expects {driverId, day, row}
        final out = <Map<String, dynamic>>[];
        for (final row in candidates) {
          final pod = _podIdFromRow(row);
          if (pod.isEmpty) continue;
          if (digits.isNotEmpty && !_podMatchesScan(pod, digits)) {
            // When searching by digits, make sure we really match
            continue;
          }
          final driverId = _driverIdFromRowOrUnknown(row);
          final day = _ymdFromRddOrNull((row['RDD Date'] ?? row['RDD'] ?? '').toString()) ?? _todayYMD();
          out.add({'driverId': driverId, 'day': day, 'row': row});
        }

        // Optional: stable sort (newest day first, then POD)
        out.sort((a, b) {
          final ad = (a['day'] as String);
          final bd = (b['day'] as String);
          final c = bd.compareTo(ad);
          if (c != 0) return c;
          final ap = _podIdFromRow(a['row'] as Map<String, dynamic>);
          final bp = _podIdFromRow(b['row'] as Map<String, dynamic>);
          return ap.compareTo(bp);
        });

        // Optional: de-dup by (driverId, day, pod)
        final seen = <String>{};
        final dedup = <Map<String, dynamic>>[];
        for (final m in out) {
          final pod = _podIdFromRow(m['row'] as Map<String, dynamic>);
          final key = '${m['driverId']}|${m['day']}|$pod';
          if (seen.add(key)) dedup.add(m);
        }
        return dedup;
      }

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16,
            top: 20,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 12,
          ),
          child: StatefulBuilder(
            builder: (ctx, set) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Global Search (last 7 days)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 20),
                TextField(
                  controller: qCtrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: (v) {
                    set(() {
                      searching = true;
                      hits = _runSearch(v);
                      searching = false;
                    });
                  },
                  onSubmitted: (v) {
                    set(() {
                      searching = true;
                      hits = _runSearch(v);
                      searching = false;
                    });
                  },
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    hintText: 'Search by DO or Customer Name',
                    hintStyle: TextStyle(fontSize: 14),
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                if (searching) const LinearProgressIndicator(),
                Flexible(
                  child: (hits.isEmpty)
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('No results yet'),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: hits.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final m = hits[i];
                            final row = (m['row'] as Map).cast<String, dynamic>();
                            final pod = _podIdFromRow(row);
                            final cust = _customerFromRow(row);
                            final day = (m['day'] as String);
                            final driverId = (m['driverId'] as String);
                            return ListTile(
                              dense: true,
                              title: Text(pod),
                              subtitle: Text('$cust\n$driverId • $day'),
                              isThreeLine: true,
                              onTap: () => Navigator.pop(sheetCtx, m),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    },
  );

  if (result == null) return;

  await _openPodDetail(
    day: result['day'] as String,
    driverId: result['driverId'] as String,
    row: (result['row'] as Map).cast<String, dynamic>(),
  );
}

Future<void> _buildGlobalIndex() async {
  _gReady = false;
  _gFull.clear(); _g9.clear(); _g6.clear();

  final rows = await loadWeekRowsFromS3();         // uses your top-level helper
  for (final e in rows) {
    if (e is! Map) continue;
    final row = Map<String, dynamic>.from(e as Map);
    final pod = _podIdFromRow(row);
    if (pod.isEmpty) continue;

    final digits = pod.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) continue;

    _gFull.add(row);

    if (digits.length >= 9) {
      final k9 = digits.substring(digits.length - 9);
      (_g9[k9] ??= <Map<String, dynamic>>[]).add(row);
    }
    if (digits.length >= 6) {
      final k6 = digits.substring(digits.length - 6);
      (_g6[k6] ??= <Map<String, dynamic>>[]).add(row);
    }
  }

  _gReady = true;
  _gBuiltAt = DateTime.now();
}

Future<void> _ensureGlobalIndex({bool force = false}) async {
  final freshEnough = _gBuiltAt != null &&
      DateTime.now().difference(_gBuiltAt!).inMinutes < 5;
  if (_gReady && !force && freshEnough) return;
  await _buildGlobalIndex();
}

@override
void initState() {
super.initState();
_load();
}

Future<void> _refresh() async {
  if (!mounted) return;
  setState(() { _loading = true; });
  try {
    await _load();
    await _ensureGlobalIndex(force: true);
    // If you later add the green-check probe, call it here:
    // await _probeApprovedForAll();
  } finally {
    if (!mounted) return;
    setState(() { _loading = false; });
  }
}

  Future<void> _probeApprovedForAll() async {
    final nowUtc = DateTime.now().toUtc();
    final my = nowUtc.add(const Duration(hours: 8));
    final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));
    final api = AdminApi();
    final updates = <String, bool>{};
    for (final d in _drivers) {
      final id = (d['driverId'] ?? '').toString();
      if (id.isEmpty) continue;
      final exists = await api.claimExists(driverId: id, day: day);
      updates[id] = exists;
    }
    if (!mounted) return;
    setState(() {
      _approvedToday.addAll(updates);
    });
  }
Future<void> _load() async {
try {
final sp = await SharedPreferences.getInstance();
final token = sp.getString(kSpAdminToken);
if (token == null || token.isEmpty) {
if (!mounted) return;
Navigator.of(context).pushReplacementNamed('/admin/login');
return;
}
final api = AdminApi();
final list = await api.drivers(token);
// Ensure an Unassigned/Unknown bucket appears in the picker
final hasUnknown = list.any((d) => (d['driverId'] ?? '').toString().toLowerCase() == 'unknown');
if (!hasUnknown) {
  list.insert(0, {'driverId': 'unknown', 'displayName': 'Unassigned', 'active': true});
}

setState(() { _token = token; _drivers = list; _loading = false; });
await _ensureGlobalIndex(force: true);

    // Probe which drivers already approved today
    _probeApprovedForAll();

} catch (e) {
setState(() { _err = e.toString(); _loading = false; });
}
}

// Extract POD id from a list row (same logic you use elsewhere)
String _podIdFromRow(Map<String, dynamic> row) {
  for (final k in const [
    'podId','POD','POD No','POD Number','Delivery No','DO No','Consignment No','Order No'
  ]) {
    final v = row[k];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
  }
  for (final entry in row.entries) {
    final name = entry.key.toLowerCase();
    if ((name.contains('pod') || name.contains('deliver') || name.startsWith('do')) &&
        entry.value != null &&
        entry.value.toString().trim().isNotEmpty) {
      return entry.value.toString().trim();
    }
  }
  return '';
}

String _customerFromRow(Map<String, dynamic> row) {
  for (final k in const ['Customer','Ship To Name','Customer Name']) {
    final v = row[k];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString();
  }
  return '';
}

// trailing-digits match (same as driver scanner)
bool _podMatchesScan(String candidatePod, String scannedRaw) {
  final podDigits  = candidatePod.replaceAll(RegExp(r'\D'), '');
  final scanDigits = scannedRaw.replaceAll(RegExp(r'\D'), '');
  if (podDigits.isEmpty || scanDigits.isEmpty) return false;

  int matchLen;
  if (podDigits.length >= 9 && scanDigits.length >= 9) {
    matchLen = 9;
  } else if (podDigits.length >= 6 && scanDigits.length >= 6) {
    matchLen = 6;
  } else {
    matchLen = [podDigits.length, scanDigits.length].reduce((a, b) => a < b ? a : b);
  }
  return podDigits.substring(podDigits.length - matchLen) ==
         scanDigits.substring(scanDigits.length - matchLen);
}

// Open Upload page on behalf (mints a token for that driver+day)
Future<void> _adminOpenUploadOnBehalf({
  required String day,           // yyyy-MM-dd
  required String driverId,
  required Map<String, dynamic> row,
}) async {
  try {
    final approve = await AdminApi().approveApp(
      adminToken: _token!,         // uses the admin token you already store
      driverId: driverId,
      day: day,
    );
    final token = (approve['token'] as String).trim();

    // Cache for background isolate reuse
    final sp = await SharedPreferences.getInstance();
    final u = driverId.toLowerCase();
    await sp.setString('sess.token.$u', token);
    await sp.setString('sess.token.$u.$day', token); // optional per-day cache

    // ...
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session.driverId', driverId);
    await prefs.setString('session.day', day);          // yyyy-MM-dd
    await prefs.setString('session.token', token);      // JWT from approveApp

    await UploadQueue.instance.rememberSession(driverId: driverId, day: day, token: token);

    final podId    = _podIdFromRow(row);
    final customer = _customerFromRow(row);
    final pd = PodData(
      rddDate: DateFormat('dd/MM/yyyy').format(DateTime.parse(day)),
      podNo: podId,
      transporter: driverId,
      customer: customer,
      address: (row['Address'] ?? '').toString(),
      quantity: (row['Quantity'] ?? '').toString(),
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UploadImagePage(
          barcode: podId,
          podDetails: pd,
          isRejected: false,             // default to delivered flow
          podData: pd,
          username: driverId.toLowerCase(),
          previousCount: 0,
          sessionToken: token,
          sessionDay: day,
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Open upload failed: $e')),
    );
  }
}

Future<void> _lookupAcrossDriversAndOpen(String scanned) async {
  if (_token == null) return;

  final scanDigits = scanned.replaceAll(RegExp(r'\D'), '');
  if (scanDigits.length < 4) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scan not recognized (need at least 4 digits)')),
      );
    }
    return;
  }

  // Warm index if needed (one-time toast)
  if (!_gReady && mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preparing 7-day index…')),
    );
  }
  try {
    await _ensureGlobalIndex();
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not build index: $e')),
      );
    }
    return;
  }

  // Candidate rows by suffix length
  List<Map<String, dynamic>> candidates = const [];
  if (scanDigits.length >= 9) {
    final k9 = scanDigits.substring(scanDigits.length - 9);
    candidates = List<Map<String, dynamic>>.from(_g9[k9] ?? const []);
  } else if (scanDigits.length >= 6) {
    final k6 = scanDigits.substring(scanDigits.length - 6);
    candidates = List<Map<String, dynamic>>.from(_g6[k6] ?? const []);
  } else {
    // 4–5 digits: fall back to a linear pass (still cheap)
    candidates = _gFull.where((row) {
      final pod = _podIdFromRow(row);
      return _podMatchesScan(pod, scanDigits);
    }).toList();
  }

  // Verify with your trailing-digits matcher and materialize matches
  final matches = <Map<String, dynamic>>[]; // {driverId, day, row}
  for (final row in candidates) {
    final pod = _podIdFromRow(row);
    if (pod.isEmpty) continue;
    if (!_podMatchesScan(pod, scanDigits)) continue;

    final driverId = _driverIdFromRowOrUnknown(row);
    final day = _ymdFromRddOrNull((row['RDD Date'] ?? row['RDD'] ?? '').toString()) ?? _todayYMD();

    matches.add({'driverId': driverId, 'day': day, 'row': row});
  }

  if (matches.isEmpty) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matching DO found (last 7 days, all drivers).')),
      );
    }
    return;
  }

  // If multiple, let admin choose
  Map<String, dynamic> pick = matches.first;
  if (matches.length > 1 && mounted) {
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Multiple matches — choose one')),
            for (final m in matches)
              ListTile(
                title: Text(_podIdFromRow(m['row'] as Map<String, dynamic>)),
                subtitle: Text('${m['driverId']} • ${(m['day'] as String)}'),
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    pick = chosen;
  }

  await _openPodDetail(
    day: pick['day'] as String,
    driverId: pick['driverId'] as String,
    row: (pick['row'] as Map).cast<String, dynamic>(),
  );
}


Future<void> _approveDriverPrompt(String driverId, String displayName) async {
  if (_token == null) return;

  final nowUtc = DateTime.now().toUtc();
  final my = nowUtc.add(const Duration(hours: 8));
  final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Approve driver?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('Approve $displayName ($driverId) for $day ?'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(dialogCtx).pop(false), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: () => Navigator.of(dialogCtx).pop(true), child: const Text('Approve')),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (ok != true) return;

  try {
    final approve = await AdminApi().approveApp(
      adminToken: _token!,
      driverId: driverId,
      day: day,
    );
    
    if (mounted) {
      setState(() { _approvedToday[driverId] = true; });
    }
    final token = (approve['token'] as String).trim();

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Approved', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Text('Approved $displayName for $day.\nTheir app will unlock automatically (no scan needed).', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: const Text('Close')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approve failed: $e')));
  }
}

void _logout() async {
final sp = await SharedPreferences.getInstance();
await sp.remove(kSpAdminToken);
if (!mounted) return;
_gFull.clear(); _g9.clear(); _g6.clear();
_gReady = false; _gBuiltAt = null;
Navigator.of(context).pushReplacementNamed('/admin/login');
}

@override
Widget build(BuildContext context) {
if (_showAdminScanner) {
  return Scaffold(
    appBar: AppBar(
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () async {
          try { await _adminScanCtrl.stop(); } catch (_) {}
          setState(() => _showAdminScanner = false);
        },
      ),
      title: const Text('Scan DO (Admin)'),
    ),
    body: MobileScanner(
      controller: _adminScanCtrl,
      onDetect: (capture) async {
        if (_adminScanBusy) return;
        _adminScanBusy = true;
        try {
          String? code;
          for (final b in capture.barcodes) {
            if (b.rawValue != null && b.rawValue!.isNotEmpty) {
              code = b.rawValue!;
              break;
            }
          }
          if (code == null) return;

          // close scanner UI first to avoid camera contention
          try { await _adminScanCtrl.stop(); } catch (_) {}
          if (mounted) setState(() => _showAdminScanner = false);

          await _lookupAcrossDriversAndOpen(code);
        } finally {
          _adminScanBusy = false;
        }
      },
    ),
  );
}

return Scaffold(
appBar: AppBar(
  title: const Text('Admin'),
  centerTitle: true,
  actions: [
    IconButton(
      tooltip: 'Global search',
      onPressed: _loading ? null : _openGlobalSearch,
      icon: const Icon(Icons.search),
    ),
    IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
    IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: 'Logout'),

],
),
body: _loading
? const Center(child: CircularProgressIndicator())
: _err != null
? Center(child: Text(_err!))
: RefreshIndicator(
    onRefresh: _refresh,
    child: ListView.separated(
      itemCount: _drivers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
        final d = _drivers[i];
        final id = (d['driverId'] ?? '').toString();
        final name = (d['displayName'] ?? id).toString();
        final active = (d['active'] ?? true) == true;
        return ListTile(
        title: Text(name),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Approve Today',
              icon: Icon(Icons.verified_user, color: (_approvedToday[id] == true) ? Colors.green : null),
              onPressed: active ? () => _approveDriverPrompt(id, name) : null,
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: active
            ? () => Navigator.of(context).pushNamed('/admin/list', arguments: {
                'driverId': id,
                'displayName': name,
              })
            : null,

        );
        },
    ),
  ),
    floatingActionButton: FloatingActionButton(
      onPressed: _loading ? null : () => setState(() => _showAdminScanner = true),
      child: const Icon(Icons.camera_alt),
    ),

);
}
}

// ====================== Admin List Screen ======================
class AdminListPage extends StatefulWidget {
  final String driverId;
  final String displayName;
  const AdminListPage({super.key, required this.driverId, required this.displayName});

  @override
  State<AdminListPage> createState() => _AdminListPageState();
}

class _AdminListPageState extends State<AdminListPage> {
  String? _adminToken;
  bool _loading = true;
  String? _err;
  bool _approvedToday = false;
  String? _cachedQrTokenDay; // e.g. '2025-09-04'
  String? _cachedQrToken;    // JWT for that day

  // --- search state (Admin list) ---
  final TextEditingController _adminSearchCtrl = TextEditingController();
  String _adminSearch = '';

  // date window (MYT): today to 6 days back
  late DateTime _todayMy;
  late DateTime _fromMy;
  late DateTime _toMy;
  StreamSubscription<QueueEvent>? _queueSub;

  // payload from /admin/list
  List<Map<String, dynamic>> _days = []; // each: { day, rows: [ {row, hasUploads}, ... ] }

  @override
  void initState() {
    super.initState();
    _initDates();
    _load();
    _deferProbe();
    // NEW: refresh this page when any queued upload completes
    _queueSub = UploadQueue.instance.events.listen((e) {
    if (!mounted) return;
    _load(); // re-fetch /admin/list so hasUploads updates
  });
}

@override
void dispose() {
  _queueSub?.cancel(); // NEW
  _adminSearchCtrl.dispose();
  super.dispose();
}

Future<void> _refresh() async {
  if (!mounted) return;
  setState(() { _loading = true; });
  try {
    await _load();
    // If you later add the green-check probe, call it here:
    // await _probeApprovalToday();
  } finally {
    if (!mounted) return;
    setState(() { _loading = false; });
  }
}


  int _probeTries = 0;
  void _deferProbe() {
    if (!mounted) return;
    if (_adminToken != null) {
      _probeApprovalToday();
      return;
    }
    if (_probeTries++ < 6) {
      Future.delayed(const Duration(milliseconds: 300), _deferProbe);
    }
  }


  Future<void> _probeApprovalToday() async {
    if (_adminToken == null) return;
    final day = _ymd(_todayMy);
    final exists = await AdminApi().claimExists(driverId: widget.driverId, day: day);
    if (!mounted) return;
    setState(() { _approvedToday = exists; });
  }


  Future<void> _approveNow() async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('Approve Today?', textAlign: TextAlign.center),
      content: Text('Approve ${widget.displayName} for today?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogCtx).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(dialogCtx).pop(true), child: const Text('Approve')),
      ],
    ),
  );
  if (ok != true) return;

  try {
    final day = _ymd(_todayMy);
    final res = await AdminApi().approveApp(
      adminToken: _adminToken!,
      driverId: widget.driverId,
      day: day,
    );
    if (!mounted) return;

    setState(() { _approvedToday = true; });

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approved'),
        content: Text('Approved ${widget.displayName} for $day.\nTheir app will unlock automatically (no scan needed).'),
        actions: [ TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')) ],
      ),
    );
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approve failed: $e')));
  }
}

  void _initDates() {
    final nowUtc = DateTime.now().toUtc();
    final my = nowUtc.add(const Duration(hours: 8));
    _todayMy = DateTime(my.year, my.month, my.day);
    _toMy = _todayMy;
    _fromMy = _todayMy.subtract(const Duration(days: 6));
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _showClaimQRForToday() async {
    if (_adminToken == null) return;

    // Today in MYT (UTC+8)
    final nowUtc = DateTime.now().toUtc();
    final my = nowUtc.add(const Duration(hours: 8));
    final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));

    // 1) Cache hit: reuse the already-minted token (no network, instant UI)
    if (_cachedQrTokenDay == day && (_cachedQrToken?.isNotEmpty ?? false)) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AdminQrPage(
            driverId: widget.driverId,
            day: day,
            token: _cachedQrToken!,
          ),
        ),
      );
      return;
    }

    // 2) Cache miss: mint a fresh token and cache it
    try {
      final approve = await AdminApi().approveApp(
        adminToken: _adminToken!,
        driverId: widget.driverId,
        day: day,
      );
      final token = (approve['token'] as String).trim();

      // update cache
      _cachedQrTokenDay = day;
      _cachedQrToken = token;

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AdminQrPage(
            driverId: widget.driverId,
            day: day,
            token: token,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('QR error: $e')),
      );
    }
  }


Future<void> _confirmAndApproveForToday() async {
  if (_adminToken == null) return;

  // Today in MYT (UTC+8)
  final nowUtc = DateTime.now().toUtc();
  final my = nowUtc.add(const Duration(hours: 8));
  final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));

  // Confirm (use dialogCtx, NOT outer context)
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Approve driver for today?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('Driver: ${widget.displayName}\nDay (MYT): $day'),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(dialogCtx).pop(false), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: () => Navigator.of(dialogCtx).pop(true), child: const Text('Approve')),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (ok != true) return;

  try {
    final approve = await AdminApi().approveApp(
      adminToken: _adminToken!,
      driverId: widget.driverId,
      day: day,
    );
    final token = (approve['token'] as String).trim();
    final claim = 'hmepod://claim?token=$token&day=$day';

    if (!mounted) return;

    // Success dialog with QR / copy / open
    // after approveApp call succeeds...
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Approved for today. Driver can tap “Check” to unlock.')),
    );

  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approve failed: $e')));
  }
}

  Future<void> _approveOnThisDeviceForToday() async {
    try {
      // Today in MYT
      final nowUtc = DateTime.now().toUtc();
      final my = nowUtc.add(const Duration(hours: 8));
      final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));

      // Mint a driver/day token
      final approve = await AdminApi().approveApp(
        adminToken: _adminToken!,
        driverId: widget.driverId,
        day: day,
      );
      final token = (approve['token'] as String).trim();

      // Save for this driver so the Driver screen unlocks without QR
      final sp = await SharedPreferences.getInstance();

      final u = widget.driverId.trim().toLowerCase();
      await sp.setString('$kSpSessTokenPrefix$u', token);
      await sp.setString('$kSpSessDayPrefix$u', day);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved ${widget.driverId} for $day (saved on this device)')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approve failed: $e')),
      );
    }
  }

Future<void> _load() async {
  setState(() { _loading = true; _err = null; });
  try {
    // admin token
    final sp = await SharedPreferences.getInstance();
    final at = sp.getString(kSpAdminToken);
    if (at == null || at.isEmpty) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/admin/login');
      return;
    }
    _adminToken = at;

    // ask the server for exactly the window we're showing
    final fromYmd = _ymd(_fromMy); // yyyy-MM-dd
    final toYmd   = _ymd(_toMy);   // yyyy-MM-dd
    final api = AdminApi();
    final m = await api.listByDriver(
      adminToken: _adminToken!,
      driverId: widget.driverId,
      fromYmd: fromYmd,
      toYmd: toYmd,
    );

    // server already returns: { days: [ { day, rows:[ {row, hasUploads, podId} ] } ] }
    final List<Map<String, dynamic>> days =
        ((m['days'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[])
            .toList();

    // Sort by day desc (yyyy-MM-dd compares lexicographically)
    days.sort((a, b) => ((b['day'] ?? '') as String).compareTo((a['day'] ?? '') as String));

    if (!mounted) return;
    setState(() {
      _days = days;
      _loading = false;
    });
    
  } catch (e) {
    if (!mounted) return;
    setState(() { _err = e.toString(); _loading = false; });
  }
}

  // ----- helpers to read POD / titles -----
  String _podIdOfRow(Map<String, dynamic> row) {
    // try common labels
    for (final k in const [
      'podId','POD','POD No','POD Number','Delivery No','DO No','Consignment No','Order No'
    ]) {
      final v = row[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    // fallback: first field whose name mentions pod/deliver/do
    for (final entry in row.entries) {
      final name = entry.key.toLowerCase();
      if ((name.contains('pod') || name.contains('deliver') || name.startsWith('do')) &&
          entry.value != null &&
          entry.value.toString().trim().isNotEmpty) {
        return entry.value.toString().trim();
      }
    }
    return '';
  }

  String _customerOfRow(Map<String, dynamic> row) {
    for (final k in const ['Customer','Ship To Name','Customer Name']) {
      final v = row[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
    return '';
  }
  List<Map<String, dynamic>> _filteredDaysForAdmin() {
  final q = _adminSearch.trim().toLowerCase();
  if (q.isEmpty) return _days;

  final out = <Map<String, dynamic>>[];
  for (final day in _days) {
    final allRows = (day['rows'] as List).cast<Map<String, dynamic>>();
    final filteredRows = allRows.where((entry) {
      final row = (entry['row'] as Map<String, dynamic>);
      final pod = _podIdOfRow(row).toLowerCase();
      final cust = _customerOfRow(row).toLowerCase();
      return pod.contains(q) || cust.contains(q);
    }).toList();
    if (filteredRows.isNotEmpty) {
      out.add({'day': day['day'], 'rows': filteredRows});
    }
  }
  return out;
}

Future<void> _actionReassign({
  required String day,
  required String fromDriverId,
  required String podId,
  String? customer, // <-- new
}) async {
  if (_adminToken == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not logged in as admin')),
    );
    return;
  }
  if (podId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Missing DO id')),
    );
    return;
  }

  // 1) Pick target driver
  final drivers = await AdminApi().drivers(_adminToken!);
  final items = drivers
      .map((d) => (d['driverId'] ?? '').toString())
      .where((id) => id.isNotEmpty && id.toLowerCase() != fromDriverId.toLowerCase())
      .toList();

  final String? toId = await showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Reassign to…')),
          for (final id in items)
            ListTile(title: Text(id), onTap: () => Navigator.pop(context, id)),
        ],
      ),
    ),
  );
  if (toId == null) return;

  // 2) Normalize the "unassigned/unknown" source for the backend
  String? _normalizeFrom(String id) {
    final s = id.trim().toLowerCase();
    // Treat unassigned/unknown/blank as "no source filter" for the backend
    if (s.isEmpty || s == 'unassigned' || s == 'unknown' || s == '-' || s == 'n/a' || s == 'na') {
      return null; // omit fromDriverId
    }
    return id;
  }

  final normFrom = _normalizeFrom(fromDriverId);
  final prettyFrom = (fromDriverId.trim().isEmpty ||
                      fromDriverId.toLowerCase() == 'unassigned' ||
                      fromDriverId.toLowerCase() == 'unknown')
      ? 'Unassigned'
      : fromDriverId;

  // 3) Confirm (now includes Customer + extra sentence)
  final cust = (customer ?? '').trim();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm Reassign',textAlign: TextAlign.center),
      content: Text([
        'DO: $podId',
        if (cust.isNotEmpty) 'Customer: $cust',
        '$prettyFrom → $toId',
        'Day: $day',
        '',
        'Are you sure? Existing files (if any) will be moved to $toId.'
      ].join('\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reassign')),
      ],
    ),
  );
  if (ok != true) return;

  // 4) Spinner
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  String mode = '';
  try {
    final res = await AdminApi().reassign(
      adminToken: _adminToken!,
      day: day,
      podId: podId,
      fromDriverId: normFrom,
      toDriverId: toId,
    );
    mode = (res['mode'] ?? '').toString();
  } catch (e) {
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reassign failed: $e')));
    }
    return;
  }

  if (mounted) Navigator.of(context, rootNavigator: true).pop();

  // 5) Success + refresh
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('DO $podId reassigned to $toId${mode.isNotEmpty ? ' ($mode)' : ''}')),
  );
  await _load();
}

  Future<void> _actionUploadOnBehalf({
    required String day,
    required String driverId,
    required Map<String, dynamic> row,
  }) async {
    // 1) Mint a session for that driver & day
    final approve = await AdminApi().approveApp(
      adminToken: _adminToken!,
      driverId: driverId,
      day: day,
    );
    final token = (approve['token'] as String).trim();

    // 2) Build a PodData for your existing UploadImagePage
    final podId = _podIdOfRow(row);
    final customer = _customerOfRow(row);
    final pd = PodData(
      rddDate: DateFormat('dd/MM/yyyy').format(DateTime.parse(day)),
      podNo: podId,
      transporter: driverId,
      customer: customer,
      address: (row['Address'] ?? '').toString(),
      quantity: (row['Quantity'] ?? '').toString(),
    );

    // 3) Open your existing uploader with session token/day for correct auth
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UploadImagePage(
          barcode: podId,
          podDetails: pd,
          isRejected: false, // you can also offer a separate “Rejected” action
          podData: pd,
          username: driverId.toLowerCase(),
          previousCount: 0,
          sessionToken: token,
          sessionDay: day,
        ),
      ),
    );

    // 4) refresh flags
    if (!mounted) return;
    await _load();
  }

  Future<void> _actionRemoveFromList({
    required String day,
    required String driverId,
    required String podId,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove from List?', textAlign: TextAlign.center),
        content: Text('This will remove DO $podId from $driverId on $day.\n'
                      'No images will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;

    final res = await AdminApi().removeFromList(
      adminToken: _adminToken!,
      day: day,
      driverId: driverId,
      podId: podId,
    );

    if (!mounted) return;
    final msg = (res['removed'] ?? 0) == 0
        ? 'Nothing removed (no exact match).'
        : 'Removed ${res['removed']} row(s).';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

Future<void> _openAddPodDialog() async {
  // same day window you already compute
  final days = <String>[];
  for (var d = _fromMy; !d.isAfter(_toMy); d = d.add(const Duration(days: 1))) {
    days.add(DateFormat('yyyy-MM-dd').format(d));
  }

  final result = await showDialog<_AddPodResult>(
    context: context,
    barrierDismissible: false, // prevent outside taps
    builder: (_) => _AddPodDialog(
      title: 'Add DO • ${widget.displayName}',
      days: days,
      initialDay: DateFormat('yyyy-MM-dd').format(_toMy),
    ),
  );

  if (result == null) return; // user cancelled

  try {
    await AdminApi().addToList(
      adminToken: _adminToken!,
      day: result.day,
      driverId: widget.driverId,
      podId: result.podId,
      customer: result.customer,
      address: result.address,
      quantity: result.quantity, // now accepts letters + numbers
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added DO ${result.podId} to ${result.day}')),
    );
    await _load();
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Add failed: $e')));
  }
}

  Widget build(BuildContext context) {
    final driverId = widget.driverId.toLowerCase();
    final title = 'Admin · ${widget.displayName}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Approve (no scan)',
            onPressed: (_adminToken == null || _loading) ? null : _approveNow,
            icon: Icon(Icons.verified_user, color: _approvedToday ? Colors.green : null), // or Icons.shield
          ),
          IconButton(
            tooltip: 'QR for Today',
            onPressed: (_adminToken == null || _loading) ? null : _showClaimQRForToday,
            icon: const Icon(Icons.qr_code_2),
          ),
          IconButton(
            tooltip: 'Add DO',
            onPressed: (_adminToken == null || _loading) ? null : _openAddPodDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(child: Text(_err!))
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: 1 + _filteredDaysForAdmin().length, // +1 for the search bar header
                itemBuilder: (context, i) {
                  if (i == 0) {
                    // --- Search header ---
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: TextField(
                        controller: _adminSearchCtrl,
                        onChanged: (v) => setState(() => _adminSearch = v),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Search by DO or Customer Name',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: (_adminSearch.isEmpty)
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    _adminSearchCtrl.clear();
                                    setState(() => _adminSearch = '');
                                  },
                                ),
                        ),
                      ),
                    );
                  }

                  final filtered = _filteredDaysForAdmin();
                  final idx = i - 1;
                  final day = filtered[idx]['day'] as String;
                  final rows = (filtered[idx]['rows'] as List).cast<Map<String, dynamic>>();

                  if (rows.isEmpty) {
                    return ListTile(
                      title: Text(_displayDay(day)),
                      subtitle: const Text('No rows'),
                    );
                  }
                  return ExpansionTile(
                    title: Text(_displayDay(day)),
                    subtitle: Text('${rows.length} item(s)'),
                    children: [
                      for (final r in rows)
                        _rowTile(day, widget.driverId.toLowerCase(), r),
                    ],
                  );
                },
              ),
            ),

    );
  }

  Widget _rowTile(String day, String driverId, Map<String, dynamic> entry) {
    final row = entry['row'] as Map<String, dynamic>;
    final has = (entry['hasUploads'] ?? false) == true;

    String _podIdOfRowLocal(Map<String, dynamic> row) {
      for (final k in const [
        'podId','POD','POD No','POD Number','Delivery No','DO No','Consignment No','Order No'
      ]) {
        final v = row[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
      }
      for (final e in row.entries) {
        final name = e.key.toLowerCase();
        if ((name.contains('pod') || name.contains('deliver') || name.startsWith('do')) &&
            e.value != null &&
            e.value.toString().trim().isNotEmpty) {
          return e.value.toString().trim();
        }
      }
      return '';
    }

    String _customerOfRowLocal(Map<String, dynamic> row) {
      for (final k in const ['Customer','Ship To Name','Customer Name']) {
        final v = row[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      return '';
    }

    final podId = _podIdOfRowLocal(row);
    final customer = _customerOfRowLocal(row);

    return ListTile(
      dense: true,
      title: Text(podId.isEmpty ? '(No DO ID)' : podId),
      subtitle: Text(customer),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(has ? Icons.check_circle : Icons.radio_button_unchecked,
              color: has ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right),
        ],
      ),
      // 👇 tap the whole row to open the new detail page
      onTap: (_adminToken == null)
          ? null
          : () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AdminPodDetailPage(
                    adminToken: _adminToken!,   // from this State
                    day: day,
                    driverId: driverId,
                    row: row,
                  ),
                ),
              );
              if (!mounted) return;
              // refresh after returning (in case of delete/reassign/upload)
              await _load();
            },
    );
  }

}

class AdminPodDetailPage extends StatelessWidget {
  final String adminToken;
  final String day;        // yyyy-MM-dd (MYT)
  final String driverId;   // current owner/assignee for this row
  final Map<String, dynamic> row;

  const AdminPodDetailPage({
    super.key,
    required this.adminToken,
    required this.day,
    required this.driverId,
    required this.row,
  });

  String _podIdOfRow(Map<String, dynamic> row) {
    for (final k in const [
      'podId','POD','POD No','POD Number','Delivery No','DO No','Consignment No','Order No'
    ]) {
      final v = row[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    for (final e in row.entries) {
      final name = e.key.toLowerCase();
      if ((name.contains('pod') || name.contains('deliver') || name.startsWith('do')) &&
          e.value != null &&
          e.value.toString().trim().isNotEmpty) {
        return e.value.toString().trim();
      }
    }
    return '';
  }

  String _customerOfRow(Map<String, dynamic> row) {
    for (final k in const ['Customer','Ship To Name','Customer Name']) {
      final v = row[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
    return '';
  }

  Future<void> _onDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove from List?',textAlign: TextAlign.center),
        content: Text('This will remove DO ${_podIdOfRow(row)} from $driverId on $day.\nNo images will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await AdminApi().removeFromList(
        adminToken: adminToken,
        day: day,
        driverId: driverId,
        podId: _podIdOfRow(row),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Removed from list.')));
        Navigator.pop(context); // back to Admin home
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Remove failed: $e')));
      }
    }
  }

  Future<void> _onReassign(BuildContext context) async {
    // 1) choose target driver
    final drivers = await AdminApi().drivers(adminToken);
    final items = drivers
        .map((d) => (d['driverId'] ?? '').toString())
        .where((id) => id.isNotEmpty && id.toLowerCase() != driverId.toLowerCase())
        .toList();

    final toId = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Reassign to…')),
            for (final id in items) ListTile(title: Text(id), onTap: () => Navigator.pop(context, id)),
          ],
        ),

      ),
    );
    if (toId == null) return;

    String? _normalizeFrom(String id) {
      final s = id.trim().toLowerCase();
      if (s.isEmpty || s == 'unassigned' || s == 'unknown' || s == '-' || s == 'n/a' || s == 'na') return null;
      return id;
    }
    final normFrom = _normalizeFrom(driverId);
    final podId = _podIdOfRow(row);
    final cust  = _customerOfRow(row);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Reassign', textAlign: TextAlign.center),
        content: Text([
          'DO: $podId',
          if (cust.isNotEmpty) 'Customer: $cust',
          '${driverId.isEmpty ? 'Unassigned' : driverId} → $toId',
          'Day: $day',
          '',
          'Are you sure? Existing files (if any) will be moved.'
        ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reassign')),
        ],
      ),
    );
    if (ok != true) return;

    // spinner
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    try {
      await AdminApi().reassign(
        adminToken: adminToken,
        day: day,
        podId: podId,
        fromDriverId: normFrom,
        toDriverId: toId,
      );
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // close spinner
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reassigned to $toId')));
        Navigator.pop(context); // back to Admin home
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reassign failed: $e')));
      }
    }
  }

  Future<void> _onUpload(BuildContext context) async {
    try {
      final approve = await AdminApi().approveApp(
        adminToken: adminToken,
        driverId: driverId,
        day: day,
      );
      final token = (approve['token'] as String).trim();

      final pd = PodData(
        rddDate: DateFormat('dd/MM/yyyy').format(DateTime.parse(day)),
        podNo: _podIdOfRow(row),
        transporter: driverId,
        customer: _customerOfRow(row),
        address: (row['Address'] ?? '').toString(),
        quantity: (row['Quantity'] ?? '').toString(),
      );

      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => UploadImagePage(
            barcode: pd.podNo,
            podDetails: pd,
            isRejected: false,      // same as your current admin “Upload on behalf…”
            podData: pd,
            username: driverId.toLowerCase(),
            previousCount: 0,
            sessionToken: token,
            sessionDay: day,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open upload failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pod = _podIdOfRow(row);
    final cust = _customerOfRow(row);
    final addr = (row['Address'] ?? '').toString();
    final qty  = (row['Quantity'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('$pod'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('📅 Date: $day', textAlign: TextAlign.center),
                Text('📦 DO Number: ${pod}', textAlign: TextAlign.center),
                Text('🏥 Customer: ${cust}', textAlign: TextAlign.center),
                Text('🔢 Quantity: $qty', textAlign: TextAlign.center),
                Text('🚚 Transporter: ${driverId.capitalizeFirst()}', textAlign: TextAlign.center),
                if (addr.isNotEmpty) Text('📍 Address: $addr'),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text('Upload DO'),
                    onPressed: () => _onUpload(context),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Reassign'),
                    onPressed: () => _onReassign(context),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete from List'),
                    onPressed: () => _onDelete(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _AddPodResult {
  final String day, podId, customer, address, quantity;
  const _AddPodResult({
    required this.day,
    required this.podId,
    this.customer = '',
    this.address = '',
    this.quantity = '',
  });
}

class _AddPodDialog extends StatefulWidget {
  final String title;
  final List<String> days;
  final String initialDay;
  const _AddPodDialog({
    super.key,
    required this.title,
    required this.days,
    required this.initialDay,
  });

  @override
  State<_AddPodDialog> createState() => _AddPodDialogState();
}

class _AddPodDialogState extends State<_AddPodDialog> {
  late String day = widget.initialDay;

  final _formKey = GlobalKey<FormState>();
  final _podCtrl  = TextEditingController();
  final _custCtrl = TextEditingController();
  final _addrCtrl = TextEditingController();
  final _qtyCtrl  = TextEditingController();

  @override
  void dispose() {
    _podCtrl.dispose();
    _custCtrl.dispose();
    _addrCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        FocusScope.of(context).unfocus(); // release keyboard before pop
        return true;
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: day,
                    items: widget.days
                        .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                        .toList(),
                    onChanged: (v) => setState(() => day = v ?? day),
                    decoration: const InputDecoration(labelText: 'Day (YYYY-MM-DD)'),
                  ),
                  TextFormField(
                    controller: _podCtrl,
                    decoration: const InputDecoration(labelText: 'DO No'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _custCtrl,
                    decoration: const InputDecoration(labelText: 'Customer (optional)'),
                  ),
                  TextFormField(
                    controller: _addrCtrl,
                    decoration: const InputDecoration(labelText: 'Address (optional)'),
                  ),
                  TextFormField(
                    controller: _qtyCtrl,
                    decoration: const InputDecoration(labelText: 'Quantity (optional)'),
                    // no keyboardType => accepts letters + numbers
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop(); // returns null
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                FocusScope.of(context).unfocus();
                Navigator.of(context).pop(_AddPodResult(
                  day: day,
                  podId: _podCtrl.text.trim(),
                  customer: _custCtrl.text.trim(),
                  address: _addrCtrl.text.trim(),
                  quantity: _qtyCtrl.text.trim(),
                ));
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

enum ScanMode { pod, claim }

class BarcodeUploaderApp extends StatefulWidget {
  const BarcodeUploaderApp({super.key});
  @override
  State<BarcodeUploaderApp> createState() => _BarcodeUploaderAppState();
}

class _BarcodeUploaderAppState extends State<BarcodeUploaderApp>
    with WidgetsBindingObserver {

  String? barcode;
  String? loggedInUsername;
  bool showScanner = false;
  Set<String> uploadedPods = {};
  Set<String> failedUploads = {};
  Set<String> ackedPods = {};
  Set<String> rejectedPods = {};
  Set<String> pendingPods = {};
  List<PodData> podDataList = [];
  String? sessionToken;   // JWT from secure QR/admin
  String? sessionDay;     // YYYY-MM-DD (MYT) for which the token is valid
  PodData? podDetails;
  bool isUploading = false;
  ScanMode _scanMode = ScanMode.pod;
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  StreamSubscription<QueueEvent>? _queueSub;
  
  // Store uploaded image URLs by POD number
  final Map<String, List<String>> podImages = {};
  final Map<String, List<File>> podImageFiles = {};
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processingScan = false;

  Widget _uploadBadge(String podNo) {
    final bool isPending =
        pendingPods.contains(podNo); // after photo taken & enqueued
    final bool isDone =
        uploadedPods.contains(podNo) || rejectedPods.contains(podNo); // upload finished (any outcome)
    final bool hasFailed =
        failedUploads.contains(podNo) && !isPending && !isDone; // permanent fail

    if (isPending) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
    }
    if (isDone) {
      // circle tick = uploaded (regardless of delivered/rejected)
      return const Icon(Icons.check_circle, color: Colors.black87, size: 28);
    }
    if (hasFailed) {
      // cross = upload permanently failed (after retries)
      return const Icon(Icons.cancel, color: Colors.black54, size: 28);
    }
    // no badge before any action
    return const SizedBox.shrink();
  }

  Future<bool> _enforceReLoginIfAppUpdated() async {
    final info = await PackageInfo.fromPlatform();
    final current = '${info.version}+${info.buildNumber}';

    final sp = await SharedPreferences.getInstance();
    final last = sp.getString('lastRunVersion');

    // First run on this device – remember version, do nothing.
    if (last == null) {
      await sp.setString('lastRunVersion', current);
      return false;
    }

    // Version changed → force logout (but keep any upload queue on disk)
    if (last != current) {
      await sp.setString('lastRunVersion', current);

      final u = sp.getString('loggedInUsername');
      await sp.remove('loggedInUsername');
      if (u != null) {
        await sp.remove('$kSpSessTokenPrefix$u');
        await sp.remove('$kSpSessDayPrefix$u');
      }

      setState(() {
        loggedInUsername = null;
        sessionToken = null;
        sessionDay = null;
      });
      return true; // we forced logout
    }

    return false; // same version, carry on
  }


  Future<void> _beginPostUploadPoll(PodData pod) async {
  // Try up to ~10s: 1s x4 then 2s x3
  for (var i = 0; i < 7; i++) {
    final ok = await _hasAckOrManifestQuick(pod);
    if (!mounted) return;
    if (ok) {
      setState(() {
        ackedPods.add(pod.podNo);
        pendingPods.remove(pod.podNo);
      });
      return;
    }
    await Future.delayed(Duration(seconds: i < 4 ? 1 : 2));
  }
}

Future<bool> _hasAckOrManifestQuick(PodData pod) async {
  final user = (loggedInUsername ?? '').toLowerCase();
  if (user.isEmpty) return false;

  final day = _ymdFromRdd(pod.rddDate);
  final bust = DateTime.now().millisecondsSinceEpoch;

  // ✓ receipt
  try {
    final r = await http.get(Uri.parse('$_bucketBase/pods/$day/$user/${pod.podNo}_receipt.json?v=$bust'));
    if (r.statusCode == 200) return true;
  } catch (_) {}

  // Fallback: manifest
  try {
    final r = await http.get(Uri.parse('$_bucketBase/pods/$day/$user/${pod.podNo}_meta.json?v=$bust'));
    if (r.statusCode == 200) return true;
  } catch (_) {}

  return false;
}


  Future<void> _loadSessionForUser(String username) async {
  final sp = await SharedPreferences.getInstance();
  final u = username.trim().toLowerCase();
  final tok = sp.getString('$kSpSessTokenPrefix$u');
  final day = sp.getString('$kSpSessDayPrefix$u');
  final today = _todayYMD();

  if (tok != null && day == today) {
    setState(() {
      sessionToken = tok;
      sessionDay = day;
    });
  } else {
    // stale or missing -> clear local state (do not force-remove stored until logout)
    setState(() {
      sessionToken = null;
      sessionDay = null;
    });
  }
}

@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);

  // Queue setup (unchanged)
  UploadQueue.instance.init();
  _queueSub = UploadQueue.instance.events.listen((e) async {
    // ... your existing listener body ...
  });

  // Run the rest async after the first frame
  Future.microtask(() async {
    // 0) Force re-login when app version changes
    final forced = await _enforceReLoginIfAppUpdated();
    await UploadQueue.instance.rescanFromDisk();
    if (forced) {
      if (mounted) setState(() {}); // show LoginPage
      return;
    }

    // 1) Admin shortcut
    final sp = await SharedPreferences.getInstance();
    final at = sp.getString(kSpAdminToken);
    if (at != null && at.isNotEmpty && mounted) {
      Navigator.of(context).pushReplacementNamed('/admin');
      return;
    }

    // 2) Normal driver init
    await loadSavedLogin(); // sets loggedInUsername (+ loads session for today)
    if (!mounted) return;

    if (loggedInUsername != null) {
      await _tryAutoClaimToday();                         // may set sessionToken/sessionDay
      await loadPodDataFromS3ForUser(loggedInUsername!);  // loads list (hides today if locked)
      await _hydrateFromS3Manifests();                    // badges/images
      if (mounted) setState(() {});                       // paint immediately
    } else {
      // no saved user → just ensure UI updates
      if (mounted) setState(() {});
    }
  });
}


@override
void didChangeAppLifecycleState(AppLifecycleState state) async {
  if (state == AppLifecycleState.resumed) {
    await UploadQueue.instance.rescanFromDisk();
    
    if (Platform.isAndroid && UploadQueue.instance.hasJobs) {
      await Workmanager().registerOneOffTask(
        'drain-upload-queue',
        'drain_uploads',
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
          requiresStorageNotLow: true,
        ),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
    }

    // ADD THIS: keep the sticky notification in sync
    await UploadNotifications.update(
      hasJobs: UploadQueue.instance.hasJobs,
      jobCount: UploadQueue.instance.jobCount,
    );
    // Pull manifests/receipts written while we were in background
    await _hydrateFromS3Manifests();

    // Clear "pending" for anything we now know is done
    if (mounted) {
      setState(() {
        pendingPods.removeWhere((p) =>
          uploadedPods.contains(p) ||
          rejectedPods.contains(p) ||
          ackedPods.contains(p));
      });
    }

  }
}

@override
void dispose() {
  _queueSub?.cancel();
  UploadQueue.instance.dispose(); // optional: if this screen "owns" the queue
  _searchCtrl.dispose();
  _scannerController.dispose();
  WidgetsBinding.instance.removeObserver(this);
  super.dispose();
}

Future<List<dynamic>> _loadWeekRows() async {
  // 1) Try the pointer file first
  final uri = Uri.parse('$_weeklyBundleUrl?v=${DateTime.now().millisecondsSinceEpoch}');
  try {
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      final root = jsonDecode(utf8.decode(res.bodyBytes));
      if (root is List) {
        // Legacy: the file itself is the bundle array
        return root;
      }
      if (root is Map) {
        // New preferred: bundle is embedded in the pointer
        final b = root['bundle'];
        if (b is List) return b.cast<dynamic>();
        // If it only has {"filename": "..."} we fall through to per-day fetch below
      }
    }
  } catch (_) {
    // ignore and fall back
  }

  // 2) Fallback: fetch the last 7 daily JSON files, newest first
  final now = _todayMY();
  final days = <DateTime>[];
  for (int i = 0; i < 7; i++) {
    final d = now.subtract(Duration(days: i));
    days.add(DateTime(d.year, d.month, d.day));
  }

  final all = <dynamic>[];
  for (final day in days) {
    List<dynamic>? rows;
    for (final url in _candidateDailyListUrls(day)) {
      try {
        final r = await http.get(url);
        if (r.statusCode == 200) {
          rows = jsonDecode(utf8.decode(r.bodyBytes)) as List<dynamic>;
          break;
        }
      } catch (_) {/* keep trying other candidate names */}
    }
    if (rows != null) all.addAll(rows);
  }
  return all;
}

Future<void> _tryAutoClaimToday() async {
  // Legacy auto-claim removed. Sessions now come only from QR/Admin flow.
  return;
}

Future<void> loadSavedLogin() async {
  final prefs = await SharedPreferences.getInstance();
  final savedUsername = prefs.getString('loggedInUsername');
  if (savedUsername != null) {
    setState(() => loggedInUsername = savedUsername);
    // load today’s session (if present) before fetching list
    await _loadSessionForUser(savedUsername);
  }
}

// --- MYT helpers (UTC+8) ---
String _todayMYT() {
  final mytNow = DateTime.now().toUtc().add(const Duration(hours: 8));
  return DateFormat('yyyy-MM-dd').format(mytNow);
}

String _claimsUrlFor(String username, String day) {
  final user = username.toLowerCase();
  final cacheBust = DateTime.now().millisecondsSinceEpoch;
  return '$kS3Base/claims/$day/$user.json?ts=$cacheBust';
}

// Fetch admin-minted claim from S3 once, then cache locally for this day
Future<bool> _fetchClaimFromS3Once(String username) async {
  final day = _todayMYT();
  final user = username.toLowerCase();
  final sp = await SharedPreferences.getInstance();

  // Per-day cache key
  final dailyKey = 'sess.token.$user.$day';
  final existing = sp.getString(dailyKey);
  if (existing != null && existing.isNotEmpty) {
    setState(() {
      sessionToken = existing;
      sessionDay   = day;
      loggedInUsername = user;
    });
    debugPrint('ENSURE -> per-day cache hit');

    return true;
  }

  final url = _claimsUrlFor(user, day);
  debugPrint('CLAIM URL => $url  (user=$user day=$day)');
  try {
    final res = await http.get(Uri.parse(url))
    .timeout(const Duration(seconds: 5));

    debugPrint('CLAIM GET status=${res.statusCode}');
    if (res.statusCode != 200) {
      debugPrint('claim GET ${res.statusCode} for $url');
      return false; // 404 → not approved yet
    }

    final map = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final fileDay = (map['day'] as String).trim();
    final tokenPreview = (map['token'] as String);
    debugPrint('CLAIM JSON day=$fileDay token.len=${tokenPreview.length}');

    final token = (map['token'] as String).trim();

    // Cache under the day provided in the file (should equal _todayMYT)
    await sp.setString('sess.token.$user.$fileDay', token);
    await sp.setString('sess.token.$user', token); // legacy
    await sp.setString('sess.day.$user', fileDay);
    debugPrint('CACHED: sess.token.$user.$fileDay present=' + ((await sp.getString('sess.token.$user.$fileDay')) != null).toString());

    if (fileDay == day) {
      setState(() {
        sessionToken = token;
        sessionDay   = day;
        loggedInUsername = user;
      });
      debugPrint('ENSURE -> per-day cache hit');

      return true;
    } else {
      debugPrint('claim day mismatch: file=$fileDay app=$day');
      return false;
    }
  } catch (e) {
    debugPrint('claim fetch error: $e');
    return false;
  }
}

// Ensure we have today's session in memory, preferring per-day cache
Future<void> _ensureSessionForToday(String username) async {
  final user = username.toLowerCase();
  final day  = _todayMYT();
  final sp = await SharedPreferences.getInstance();
  debugPrint('_ensureSessionForToday(user=$user day=$day)');

  // 1) Per-day cached token
  final perDay = sp.getString('sess.token.$user.$day');
  if (perDay != null && perDay.isNotEmpty) {
    setState(() {
      sessionToken = perDay;
      sessionDay   = day;
      loggedInUsername = user;
    });
    debugPrint('ENSURE -> per-day cache hit');

    return;
  }

  // 2) Legacy key if its day matches today
  final t = sp.getString('sess.token.$user');
  final d = sp.getString('sess.day.$user');
  if (t != null && d == day) {
    setState(() {
      sessionToken = t;
      sessionDay   = d;
      loggedInUsername = user;
    });
    debugPrint('ENSURE -> legacy cache hit');
    return;
  }
  debugPrint('ENSURE -> no local token, fetching from S3…');
  // 3) Nothing local → fetch once from S3
  await _fetchClaimFromS3Once(user);
}


Future<void> loadPodDataFromS3ForUser(String username) async {
    await _ensureSessionForToday(username);
  setState(() {
    podDataList = [];
    podImages.clear();
  });

  // Only show today's rows if the secure session for today is present
  final includeToday = (sessionToken != null && sessionDay == _todayYMD());
  debugPrint('includeToday=$includeToday  sessionDay=$sessionDay  today=${_todayYMD()}');

  // 1) Load week rows from pointer (bundle) or fallback to per-day fetch
var rows = await _loadWeekRows();
  // If approved for today, overlay today's rows from the API (auth-only)
  if (includeToday && sessionToken != null) {
    try {
      final uri = Uri.parse('$kApiBase/lists/today/${username.toLowerCase()}.json');
      final res = await http.get(uri, headers: {'Authorization': 'Bearer $sessionToken'});
      if (res.statusCode == 200) {
        final todayRows = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
        // Prepend so "newest wins" when we dedupe by POD later
        rows = [...todayRows, ...rows];
      } else {
        debugPrint('today list api ${res.statusCode}: ${res.body}');
      }
    } catch (e) {
      debugPrint('today list api error: $e');
    }
  }

if (rows.isEmpty) {
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No list data found for the past 7 days.')),
    );
  }
  return;
}

  // 2) Filter by driver and (optionally) hide today
  // The bundle is newest-first, so first occurrence of a POD is the newest.
  final Map<String, Map<String, dynamic>> byPod = {}; // POD -> row (newest wins)
  int total = 0;

  for (final e in rows) {
    if (total >= 100) break; // cap like before
    final m = Map<String, dynamic>.from(e as Map);

    if (!_rowMatchesUser(m, username)) continue;

    if (!includeToday) {
      final rddYmd = _ymdFromRddOrNull((m['RDD Date'] ?? '').toString());
      if (rddYmd == null) continue;
      if (rddYmd == _todayYMD()) continue; // hide today's rows until unlocked
    }

    final pod = (m['POD No'] ?? m['POD'] ?? m['pod'] ?? '').toString().trim();
    if (pod.isEmpty) continue;

    // first time we see this POD -> keep (bundle is newest-first)
    if (!byPod.containsKey(pod)) {
      byPod[pod] = m;
      total++;
    }
  }

  // 3) Materialize + sort by RDD desc (same logic you already had)
  final out = byPod.values.map((m) => PodData.fromJson(m)).toList();
  DateTime p(String s) {
    try { return DateFormat('dd/MM/yy').parse(s); } catch (_) {}
    try { return DateFormat('dd/MM/yyyy').parse(s); } catch (_) {}
    return DateTime(1970, 1, 1);
  }
  out.sort((a, b) => p(b.rddDate).compareTo(p(a.rddDate)));

  if (!mounted) return;
  setState(() { podDataList = out; });

  // 4) Hydrate upload status from S3 manifests (unchanged)
  await _hydrateFromS3Manifests();
}

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final u = loggedInUsername;
    await prefs.remove('loggedInUsername');
    if (u != null) {
      await prefs.remove('$kSpSessTokenPrefix$u');
      await prefs.remove('$kSpSessDayPrefix$u');
    }
    setState(() {
      loggedInUsername = null;
      sessionToken = null;
      sessionDay = null;
    });
  }

  Future<void> _confirmLogout() async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Logout?', textAlign: TextAlign.center),
      content: const Text('You will be signed out of this device.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Logout'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await logout();
  }
}

Future<void> openUploadPage(bool isRejected) async {
  if (barcode == null || podDetails == null) return;

  // Capture BEFORE awaiting
  final selectedPod = podDetails!;
  final selectedPodNo = selectedPod.podNo;

  final result = await Navigator.push<UploadResult>(
    context,
    MaterialPageRoute(
      builder: (_) => UploadImagePage(
        barcode: barcode!,
        podDetails: selectedPod,
        isRejected: isRejected,
        podData: selectedPod,
        username: loggedInUsername!,
        previousCount: (podImages[selectedPodNo] ?? []).length,
        sessionToken: sessionToken,
        sessionDay: sessionDay,
      ),
    ),
  );

  if (!mounted || result == null) return;

  // If we got camera files, queue them for background upload
  if (result.localFiles != null && result.localFiles!.isNotEmpty) {
    final filesToUpload = result.localFiles!.map((f) => f.path).toList();

    await UploadQueue.instance.enqueue(
      UploadJob(
        id: '${selectedPodNo}-${DateTime.now().millisecondsSinceEpoch}',
        username: loggedInUsername!,
        podNo: selectedPodNo,
        rddDate: selectedPod.rddDate,
        isRejected: isRejected,
        imagePaths: filesToUpload,
        sessionToken: sessionToken,  // ok if null for old PODs
        sessionDay: sessionDay,      // ok if null for old PODs
        attempts: 0,
      ),
    );

    // Immediately flip row color and show "…"
    setState(() {
      if (isRejected) {
        rejectedPods.add(selectedPodNo);
        uploadedPods.remove(selectedPodNo);
      } else {
        uploadedPods.add(selectedPodNo);
        rejectedPods.remove(selectedPodNo);
      }
      ackedPods.remove(selectedPodNo); // we don't have ✓ yet
      pendingPods.add(selectedPodNo);  // show "…"
    });

    // Start quick poll to turn "…" into ✓ when receipt/manifest shows up
    _beginPostUploadPoll(selectedPod);

    // keep local preview
    podImageFiles[selectedPodNo] = result.localFiles!;
  }

  // keep any URLs handed back (if any)
  setState(() {
    podImages[selectedPodNo] = result.urls;
    // Clear detail state
    barcode = null;
    podDetails = null;
  });

  // Background hydrate (won't wipe the immediate flags if you use set unions)
  await _hydrateFromS3Manifests();
}

  Future<Map<String, dynamic>?> _fetchPodManifest(PodData pod) async {
    final dayStr = _ymdFromRdd(pod.rddDate);
    final baseUser = (loggedInUsername ?? '').trim();
    final candidates = <String>[
      baseUser.toLowerCase(),
      baseUser,
    ].toSet().toList(); // dedupe if same

    for (final user in candidates) {
      if (user.isEmpty) continue;
      final uri = Uri.parse(
        '$_bucketBase/pods/$dayStr/$user/${pod.podNo}_meta.json'
        '?v=${DateTime.now().millisecondsSinceEpoch}'
      );
      try {
        final res = await http.get(uri);
        if (res.statusCode == 200) {
          return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        }
        if (res.statusCode == 404 || res.statusCode == 403) {
          continue; // try next candidate
        }
      } catch (_) {
        // ignore and try next
      }
    }
    return null;
  }


Future<void> _hydrateFromS3Manifests() async {
  // Build into temps so UI doesn’t go blank mid-hydrate
  final nextUploaded  = <String>{};
  final nextRejected  = <String>{};
  final nextAcked     = <String>{};
  final nextPodImages = <String, List<String>>{};

  final futures = <Future<void>>[];
  for (final pod in podDataList) {
    futures.add(() async {
      // 1) Fetch manifest (try your helper)
      Map<String, dynamic>? data = await _fetchPodManifest(pod);
      bool ackFound = false;
      String? driverForPod;

      if (data != null) {
        final status = (data['status'] as String?)?.toLowerCase() ?? '';
        final urls = (data['urls'] as List?)?.map((e) => e.toString()).toList()
                     ?? const <String>[];
        nextPodImages[pod.podNo] = urls;
        if (status == 'delivered') nextUploaded.add(pod.podNo);
        if (status == 'rejected')  nextRejected.add(pod.podNo);

        // who actually uploaded (folder owner)
        driverForPod = (data['updatedBy'] as String?)?.toLowerCase();
      }

      // 2) Check for server ACK receipt (✓) under the correct folder
      final dayStr = _ymdFromRdd(pod.rddDate);
      final candidates = <String>{
        if (driverForPod != null && driverForPod!.isNotEmpty) driverForPod!,
        if (loggedInUsername != null) loggedInUsername!.toLowerCase(),
        if (loggedInUsername != null) loggedInUsername!,
      }.toList(); // dedup via set, then list

      for (final drv in candidates) {
        if (drv.isEmpty) continue;
        final receiptUri = Uri.parse(
          '$_bucketBase/pods/$dayStr/$drv/${pod.podNo}_receipt.json'
          '?v=${DateTime.now().millisecondsSinceEpoch}'
        );
        try {
          final r = await http.get(receiptUri);
          if (r.statusCode == 200) {
            nextAcked.add(pod.podNo);
            ackFound = true;
            break;
          }
        } catch (_) {}
      }

      // 3) Clean up queue copies only after success (manifest OR receipt exists)
      if (loggedInUsername != null && (data != null || ackFound)) {
        await UploadQueue.instance.deleteQueueCopiesForPod(
          username: loggedInUsername!,
          podNo: pod.podNo,
        );
      }

    }());
  }

  await Future.wait(futures);
  await UploadQueue.instance.rescanFromDisk();

  if (!mounted) return;
  setState(() {
    // IMPORTANT: merge (union) so we don't lose instant state from the listener
    uploadedPods = {...uploadedPods, ...nextUploaded};
    rejectedPods = {...rejectedPods, ...nextRejected};
    ackedPods    = {...ackedPods,    ...nextAcked};
    podImages
      ..clear()
      ..addAll(nextPodImages);
    pendingPods.removeWhere((p) =>
    nextUploaded.contains(p) ||
    nextRejected.contains(p) ||
    nextAcked.contains(p));
    pendingPods.removeWhere((p) => nextUploaded.contains(p) || nextRejected.contains(p));
  });
}

  List<Object> _groupedItemsByDay(List<PodData> items) {
    final byDay = <String, List<PodData>>{};
    for (final p in items) {
      final key = _ymdFromRddOrNull((p.rddDate).trim());
      if (key == null) continue;
      (byDay[key] ??= []).add(p);
    }

    final ordered = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

    final out = <Object>[];
    for (final ymd in ordered) {
      out.add({'header': ymd, 'count': byDay[ymd]!.length});
      out.addAll(byDay[ymd]!);
    }
    return out;
  }

  // Same grouping, but with a case-insensitive filter on POD or Customer
List<Object> _groupedItemsByDayFiltered(List<PodData> items, String query) {
  final q = query.trim().toLowerCase();
  final filtered = (q.isEmpty)
      ? items
      : items.where((p) {
          final pod = (p.podNo).toLowerCase();
          final cust = (p.customer).toLowerCase();
          return pod.contains(q) || cust.contains(q);
        }).toList();
  return _groupedItemsByDay(filtered);
}

  @override
  Widget build(BuildContext context) {
    
    if (loggedInUsername == null) {
      return LoginPage(
        onLoginSuccess: (username) async {
          final prefs = await SharedPreferences.getInstance();
          final u = username.trim().toLowerCase();
          await prefs.setString('loggedInUsername', u);
          setState(() => loggedInUsername = u);

          // hydrate session (if admin already approved on this device)
          await _loadSessionForUser(username);
          await _tryAutoClaimToday();   // <-- get today's token immediately after login
          await loadPodDataFromS3ForUser(username);
          await _hydrateFromS3Manifests();   // <-- add

          if (mounted) setState(() {});      // <-- add (forces list to show immediately)
        },

      );
    }

    if (showScanner) {
      
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => showScanner = false),
          ),
          title: Text(_scanMode == ScanMode.claim ? 'Scan Approval QR' : 'Scan DO'),
        ),
        body: MobileScanner(
          controller: _scannerController,
          onDetect: (capture) async {
            if (_processingScan) return; // prevent double trigger
            _processingScan = true;

            try {
              String? code;
              for (final b in capture.barcodes) {
                if (b.rawValue != null && b.rawValue!.isNotEmpty) {
                  code = b.rawValue!;
                  break;
                }
              }
              if (code == null) return;

              // 1) Secure-claim QR: hmepod://claim?token=...&day=YYYY-MM-DD  OR  {"token":"...","day":"YYYY-MM-DD"}
              if (code.startsWith('hmepod://claim')) {
                try {
                  final uri = Uri.parse(code.replaceFirst('hmepod://', 'https://dummy/'));
                  final t = uri.queryParameters['token'];
                  final d = uri.queryParameters['day'];
                  if (t != null && d != null) {
                    setState(() {
                      sessionToken = t;
                      sessionDay = d;
                      showScanner = false;
                    });
                    // Persist for this driver so app stays unlocked for today
                    final sp = await SharedPreferences.getInstance();
                    if (loggedInUsername != null) {
                      final u = loggedInUsername!.trim().toLowerCase();
                      await sp.setString('$kSpSessTokenPrefix$u', t);
                      await sp.setString('$kSpSessDayPrefix$u', d);
                      await sp.setString('sess.token.$u.$d', t); // per-day cache for today

                    }
                    await loadPodDataFromS3ForUser(loggedInUsername!);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Today unlocked')));
                    _processingScan = false;
                    return;
                  }
                } catch (_) {}
              }
              if (code.startsWith('{') && code.contains('"token"') && code.contains('"day"')) {
                try {
                  final m = jsonDecode(code) as Map<String, dynamic>;
                  final t = m['token']?.toString();
                  final d = m['day']?.toString();
                  if (t != null && d != null) {
                    setState(() {
                      sessionToken = t;
                      sessionDay = d;
                      showScanner = false;
                    });
                    // Persist for this driver so app stays unlocked for today
                    final sp = await SharedPreferences.getInstance();
                    if (loggedInUsername != null) {
                      final u = loggedInUsername!.trim().toLowerCase();
                      await sp.setString('$kSpSessTokenPrefix$u', t);
                      await sp.setString('$kSpSessDayPrefix$u', d);
                      await sp.setString('sess.token.$u.$d', t); // per-day cache for today

                    }
                    await loadPodDataFromS3ForUser(loggedInUsername!);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Today unlocked')));
                    _processingScan = false;
                    return;
                  }
                } catch (_) {}
              }
              // 2) Treat as POD barcode by trailing digits (accept letters too)
              final scanDigits = code.replaceAll(RegExp(r'\D'), '');
              if (scanDigits.length < 4) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Scan not recognized (need at least 4 digits)')),
                  );
                }
                return;
              }

              final match = podDataList.firstWhere(
                (e) {
                  final podDigits = (e.podNo).replaceAll(RegExp(r'\D'), '');
                  if (podDigits.isEmpty) return false;

                  int matchLen;
                  if (podDigits.length >= 9 && scanDigits.length >= 9) {
                    matchLen = 9;
                  } else if (podDigits.length >= 6 && scanDigits.length >= 6) {
                    matchLen = 6;
                  } else {
                    matchLen = min(podDigits.length, scanDigits.length);
                  }

                  return podDigits.substring(podDigits.length - matchLen) ==
                        scanDigits.substring(scanDigits.length - matchLen);
                },
                orElse: () => PodData.empty(),
              );

              if (match.podNo.isEmpty) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('No matching DO found in your list. If today is locked, scan your approval QR first.'),
                    ),
                  );
                }
                return;
              }

              try {
                await _scannerController.stop();
              } catch (e) {
                debugPrint('Scanner stop ignored: $e');
              }
              setState(() => showScanner = false);

              if (uploadedPods.contains(match.podNo) || rejectedPods.contains(match.podNo)) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AlreadyUploadedPage(
                      pod: match,
                      barcode: match.podNo,
                      imageUrls: podImages[match.podNo] ?? [],
                      onReuploadConfirmed: () async {
                        final count = (podImages[match.podNo] ?? []).length;
                        final sure = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Confirm Reupload', textAlign: TextAlign.center),
                            content: Text('This DO already has $count image(s). Replace them?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes')),
                            ],
                          ),
                        );
                        if (sure != true) return;
                        setState(() {
                          barcode = match.podNo;
                          podDetails = match;
                        });
                        Navigator.pop(context);
                      },
                      onDeleted: () async {
                        setState(() {
                          uploadedPods.remove(match.podNo);
                          rejectedPods.remove(match.podNo);
                          podImages[match.podNo] = [];
                        });
                        await _hydrateFromS3Manifests();
                      },
                    ),
                  ),
                );
              } else {
                setState(() {
                  barcode = code;
                  podDetails = match;
                });
              }
            } finally {
              _processingScan = false;
            }
          },
        ),

      );
    }

    if (barcode != null && podDetails != null) {
      final files = podImageFiles[podDetails!.podNo] ?? [];
      return WillPopScope(
        onWillPop: () async {
          setState(() {
            barcode = null;
            podDetails = null;
          });
          return false; // consume the back press
        },
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            automaticallyImplyLeading: false,
            leading: IconButton(
              onPressed: () {
                if (isUploading) return;
                setState(() {
                  barcode = null;
                  podDetails = null;
                });
              },
              icon: const Icon(Icons.arrow_back),
            ),
            title: Text('DO ${podDetails!.podNo}'),
          ),
            body: Center(
  child: SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('📦 DO Number: ${podDetails!.podNo}', style: const TextStyle(fontSize: 16)),
          Text('🏥 Customer: ${podDetails!.customer}'),
          Text('🔢 Quantity: ${podDetails!.quantity}'),

          // Previous photos (if any)
          if (files.isNotEmpty) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: files.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final f = files[i];
                  return GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FullscreenGalleryPage(
                            images: files,
                            initialIndex: i,
                          ),
                        ),
                      );
                    },
                    child: Hero(
                      tag: f.path,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(f, height: 120, width: 120, fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],

          const SizedBox(height: 24),
          SizedBox(
            width: 320,
            height: 48,
            child: ElevatedButton(
              onPressed: () => openUploadPage(false),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text('Item Delivered'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            height: 48,
            child: ElevatedButton(
              onPressed: () => openUploadPage(true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Item Rejected'),
            ),
          ),
        ],
      ),
    ),
  ),
),
    ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        automaticallyImplyLeading: true,
        title: const Text('Delivery List'),
        actions: [
          IconButton(
            tooltip: 'Retry pending uploads',
            onPressed: () async {
              await UploadQueue.instance.rescanFromDisk();
              await _hydrateFromS3Manifests();
            },
            icon: const Icon(Icons.cloud_sync),
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: 'Logout', onPressed: _confirmLogout),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100), // was 40
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Today locked banner (shows until a valid sessionToken for today's day exists)
            if (!(sessionToken != null && sessionDay == _todayYMD())) ...[
                Builder(
                  builder: (_) {
                    debugPrint(
                      'BANNER LOCKED because '
                      'sessionToken=${sessionToken == null ? 'null' : 'set'} '
                      'sessionDay=$sessionDay '
                      'today=${_todayYMD()}',
                    );
                    return const SizedBox.shrink();
                  },
                ),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_clock),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Today is locked. Scan your QR to unlock today\'s list and upload.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _scanMode = ScanMode.claim;   // <-- claim-only
                            showScanner = true;
                          }),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
            ],
              // --- Search bar (POD No or Customer) ---
            TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _search = v),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by DO or Customer Name',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: (_search.isEmpty)
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  // Always rescan jobs from disk (local-only, fast)
                  await UploadQueue.instance.rescanFromDisk();

                  // Try to unlock today quickly, but don't hang forever
                  if (loggedInUsername != null) {
                    try {
                      await _tryAutoClaimToday()
                          .timeout(const Duration(seconds: 3), onTimeout: () => null);
                    } catch (_) {/* best-effort */}
                    // Kick off the list fetch in the background so UI doesn't wait
                    Future.microtask(() async {
                      try {
                        await loadPodDataFromS3ForUser(loggedInUsername!);
                      } catch (_) {/* ignore */}
                    });
                  } else {
                    // Also background if no user selected
                    Future.microtask(() async {
                      try {
                        await _hydrateFromS3Manifests();
                      } catch (_) {/* ignore */}
                    });
                  }

                  // <-- IMPORTANT: end the refresh *now*. UI stops spinning immediately.
                  return;
                },

                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _groupedItemsByDayFiltered(podDataList, _search).length,
                    itemBuilder: (c, i) {
                      final data = _groupedItemsByDayFiltered(podDataList, _search);
                      final obj = data[i];
                      if (obj is Map && obj.containsKey('header')) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('🗓 ${_displayDay(obj['header'] as String)}',
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text('${obj['count']} items'),
                            ],
                          ),
                        );
                      }
                      final pod = obj as PodData;
                      final bool done = uploadedPods.contains(pod.podNo) || rejectedPods.contains(pod.podNo);
                      final bool pending = pendingPods.contains(pod.podNo);
                      return GestureDetector(
                        onTap: () {
                          if (done) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AlreadyUploadedPage(
                                  pod: pod,
                                  barcode: pod.podNo,
                                  imageUrls: podImages[pod.podNo] ?? [],
                                  onReuploadConfirmed: () async {
                                    final count = (podImages[pod.podNo] ?? []).length;

                                    final sure = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        title: const Text('Confirm Reupload', textAlign: TextAlign.center),
                                        content: Text('This DO already has $count image(s). Replace them?'),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes')),
                                        ],
                                      ),
                                    );
                                    if (sure != true) return;

                                    setState(() {
                                      barcode = pod.podNo;
                                      podDetails = pod;
                                    });
                                    Navigator.pop(context);
                                  },
                                    onDeleted: () async {
                                      setState(() {
                                        uploadedPods.remove(pod.podNo);
                                        rejectedPods.remove(pod.podNo);
                                        podImages[pod.podNo] = [];
                                      });
                                      await _hydrateFromS3Manifests();
                                    },
                                ),
                              ),
                            );
                          } else {
                            setState(() {
                              barcode = pod.podNo;
                              podDetails = pod;
                            });
                          }
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: done
                                ? (uploadedPods.contains(pod.podNo) ? Colors.green[100] : Colors.red[100])
                                : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // main content (leave space on the right for the badge)
                              Padding(
                                padding: const EdgeInsets.only(right: 44),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '📦 DO: ${pod.podNo}',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Text('🏥 Customer: ${pod.customer}'),
                                    Text('🔢 Qty: ${pod.quantity}'),
                                  ],
                                ),
                              ),
                              // badge: vertically centered on the right
                              Positioned.fill(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: _uploadBadge(pod.podNo),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
              ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() {
          _scanMode = ScanMode.pod;     // <-- pod-only
          showScanner = true;
        }),
        child: const Icon(Icons.camera_alt),
      ),
    );
  }
}

class PodData {
  final String rddDate, podNo, transporter, customer, address, quantity;
  PodData({required this.rddDate, required this.podNo, required this.transporter, required this.customer, required this.address, required this.quantity});
  factory PodData.fromJson(Map<String, dynamic> j) => PodData(
        rddDate: j['RDD Date'], podNo: j['POD No'].toString(), transporter: j['Driver'], customer: j['Customer'].toString(), address: j['Address'], quantity: j['Quantity'].toString(),
      );
  factory PodData.empty() => PodData(rddDate: '', podNo: '', transporter: '', customer: '', address: '', quantity: '');
}

class UploadImagePage extends StatefulWidget {
  final String barcode;
  final PodData podDetails;
  final bool isRejected;
  final PodData podData;
  final int previousCount;
  final String username;
  final String? sessionToken;
  final String? sessionDay;

  const UploadImagePage({
  super.key,
  required this.barcode,
  required this.podDetails,
  required this.isRejected,
  required this.podData,
  required this.username,
  this.previousCount = 0,
  this.sessionToken,
  this.sessionDay,
});

  @override _UploadImagePageState createState() => _UploadImagePageState();
}

class _UploadImagePageState extends State<UploadImagePage> {
  static const _signEndpoint = 'https://s3-upload-api-trvm.onrender.com/sign';

  Map<String,String> _headersForKey(String contentType, String key) {
    final String? sd = widget.sessionDay;
    final bool canUseJwt = (widget.sessionToken != null) &&
                          sd != null &&
                          key.startsWith('pods/$sd/');
    if (!canUseJwt) {
      throw StateError('no_session_for_day');
    }
    return {
      'Content-Type': contentType,
      'Authorization': 'Bearer ${widget.sessionToken!}',
    };
  }
  final List<File> images = [];
  final picker = ImagePicker();
  bool isUploading = false;

Future<void> pickImage() async {
final XFile? img = await picker.pickImage(
  source: ImageSource.camera,
  imageQuality: 75,    // smaller, faster; still clear
  maxWidth: 1600,      // downscale very large images
  maxHeight: 1200,
);

  if (!mounted) return;
  if (img != null) setState(() => images.add(File(img.path)));
}

Future<void> _removeImageAt(int index) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Remove photo?'),
      content: const Text('This photo will be removed from the upload.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
      ],
    ),
  );
  if (ok == true && mounted) {
    setState(() {
      images.removeAt(index);
    });
  }
}

  void logError(String stage, http.Response res) {
    debugPrint(
      '[$stage] ${res.statusCode} ${res.reasonPhrase} '
      '${res.body.isNotEmpty ? res.body.substring(0, 200) : ""}'
    );
  }

  Future<void> uploadImagesToS3() async {
  if (images.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('📸 Please take at least one picture first')),
    );
    return;
  }

  // Build a job
  final id = '${widget.podData.podNo}-${DateTime.now().millisecondsSinceEpoch}';
  final job = UploadJob(
    id: id,
    username: widget.username.toLowerCase(),
    podNo: widget.podData.podNo,
    rddDate: widget.podData.rddDate,   // keep original display date
    isRejected: widget.isRejected,
    sessionToken: widget.sessionToken,
    sessionDay: widget.sessionDay,
    imagePaths: images.map((f) => f.path).toList(),
  );

  await UploadQueue.instance.enqueue(job);

  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Saved & syncing in background…')),
  );

  // Return "pending" so parent can mark the POD amber
  Navigator.pop(
    context,
    UploadResult(const [], PodStatus.pending, localFiles: List<File>.from(images)),
  );
}

Future<void> _writeManifestToS3(List<String> urls) async {
  // Use full POD number for the manifest path and payload
  final String podNoFull = widget.podData.podNo;
  final String status = widget.isRejected ? 'rejected' : 'delivered';

  final manifest = {
    'podNo': podNoFull,
    'status': status,
    'urls': urls,
    'updatedBy': widget.username,
    'updatedAt': DateTime.now().toIso8601String(),
  };

  // Store at: pods/<day>/<driver>/<POD>_meta.json
  final String dayStr3 = _ymdFromRdd(widget.podData.rddDate);
  final String filename = 'pods/$dayStr3/${widget.username}/${podNoFull}_meta.json';

  final payload = jsonEncode({'filename': filename, 'contentType': 'application/json'});
  final presignRes = await http.post(
    Uri.parse(_signEndpoint),
    headers: _headersForKey('application/json', filename),
    body: payload,
  );

if (presignRes.statusCode != 200) {
  logError('signManifest', presignRes);
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not prepare manifest upload.')),
    );
  }
  return;
}

  final signedUrl = jsonDecode(presignRes.body)['url'] as String;

  final putRes = await http.put(
    Uri.parse(signedUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(manifest),
  );

  if (putRes.statusCode != 200) {
  logError('putManifest', putRes);
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saving manifest failed.')),
    );
  }
  return;
}

}

  @override
Widget build(BuildContext c) {
    final pd = widget.podData;

      return WillPopScope(
        onWillPop: () async {
          if (isUploading) {
            ScaffoldMessenger.of(c).showSnackBar(
              const SnackBar(content: Text('Please wait, uploading...')),
            );
            return false;
          }
          return true;
        },
        child: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            // Also disable the top-left back button during upload
            onPressed: isUploading ? null : () => Navigator.pop(c),
          ),
          title: Text(widget.isRejected ? 'Item Rejected' : 'Item Delivered'),
        ),
      body: Center( // centers horizontally
  child: SingleChildScrollView( // keeps things visible on small screens
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Force true centering by constraining width
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('📦 DO Number: ${pd.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              Text('🏥 Customer: ${pd.customer}', textAlign: TextAlign.center),
              Text('🔢 Quantity: ${pd.quantity}', textAlign: TextAlign.center),
              Text('🚚 Transporter: ${pd.transporter}', textAlign: TextAlign.center),

              const SizedBox(height: 12),

              // make the (+) row always visible and obvious
              Container(
                height: 120,
                alignment: Alignment.centerLeft,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  itemCount: images.length + 1, // +1 = (+) tile
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return GestureDetector(
                        onTap: pickImage,
                        child: Container(
                          width: 120,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade500, width: 2),
                            color: Colors.white, // contrast so it's visible
                          ),
                          child: const Center(child: Icon(Icons.add, size: 40)),
                        ),
                      );
                    }
                    final file = images[i - 1];
                    return Stack(
                      children: [
                        // Tap to preview, long-press to delete
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => FullscreenGalleryPage(
                                  images: images,
                                  initialIndex: i - 1,
                                ),
                              ),
                            );
                          },
                          onLongPress: () => _removeImageAt(i - 1),
                          child: Hero(
                            tag: file.path,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                file,
                                height: 120,
                                width: 120,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),

                        // Little "X" in the corner to remove
                        Positioned(
                          right: 4,
                          top: 4,
                          child: Material(
                            color: Colors.black54,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _removeImageAt(i - 1),
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(Icons.close, size: 18, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

                  },
                ),
              ),

              const SizedBox(height: 24),

              SizedBox(
                width: 320,
                height: 48,
                child: ElevatedButton(
                  onPressed: (!isUploading && images.isNotEmpty) ? uploadImagesToS3 : null,
                  child: isUploading ? const CircularProgressIndicator() : const Text('Upload Image'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  ),
),
      ),
    );
  }

}

// Complete Admin API client
class AdminApi {
  final http.Client _http;
  final String base;

  AdminApi({http.Client? httpClient, String? apiBase})
      : _http = httpClient ?? http.Client(),
        base = apiBase ?? kApiBase;

Future<bool> claimExists({required String driverId, required String day}) async {
  final uri = Uri.parse('$base/claim_poll');
  final sp = await SharedPreferences.getInstance();
  final adminToken = sp.getString(kSpAdminToken) ?? '';
  if (adminToken.isEmpty) throw Exception('no_admin_token');

  final r = await _http.post(
    uri,
    headers: {'Authorization': 'Bearer $adminToken', 'Content-Type': 'application/json'},
    body: jsonEncode({'driverId': driverId, 'day': day}),
  );
  if (r.statusCode == 200) return true;
  if (r.statusCode == 404) return false; // not ready
  throw Exception('claim_poll_failed:${r.statusCode}:${r.body}');
}

// ---- Auth ----------------------------------------------------

  /// POST /admin/login  -> { token }
  Future<String> login(String password) async {
    final uri = Uri.parse('$base/admin/login');
    final r = await _http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'password': password}),
    );
    if (r.statusCode != 200) {
      throw Exception('Login failed (${r.statusCode}): ${r.body}');
    }
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final token = (m['token'] as String?)?.trim();
    if (token == null || token.isEmpty) {
      throw Exception('No token returned');
    }
    return token;
  }

  // ---- Directory ------------------------------------------------

  /// GET /admin/drivers  -> [ {driverId, displayName, ...}, ... ]
  Future<List<Map<String, dynamic>>> drivers(String adminToken) async {
    final uri = Uri.parse('$base/admin/drivers');
    final r = await _http.get(uri, headers: {
      'Authorization': 'Bearer $adminToken',
    });
    if (r.statusCode != 200) {
      throw Exception('Drivers failed (${r.statusCode}): ${r.body}');
    }
    final v = jsonDecode(r.body);
    if (v is List) {
      return v.cast<Map<String, dynamic>>();
    }
    throw Exception('Unexpected drivers payload');
  }

  // ---- Lists (plan + hasUploads flag) ---------------------------

  /// GET /admin/list?driverId=&from=YYYY-MM-DD&to=YYYY-MM-DD
  /// Returns: { driverId, from, to, days: [ { day, rows: [ {row:{...}, hasUploads:bool}, ...] }, ... ] }
  Future<Map<String, dynamic>> listByDriver({
    required String adminToken,
    required String driverId,
    required String fromYmd,
    required String toYmd,
  }) async {
    final uri = Uri.parse('$base/admin/list?driverId=$driverId&from=$fromYmd&to=$toYmd');
    final r = await _http.get(uri, headers: {'Authorization': 'Bearer $adminToken'});
    if (r.statusCode != 200) {
      throw Exception('Admin list failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ---- Approvals (mint driver/day JWT) --------------------------

  /// POST /admin/approve_app {driverId, depot, day} -> { token, day, depot, prefix, expiresAt }
  Future<Map<String, dynamic>> approveApp({
    required String adminToken,
    required String driverId,
    required String day, // YYYY-MM-DD (MYT)
    String depot = 'MY-KL',
  }) async {
    final uri = Uri.parse('$base/admin/approve_app');
    final r = await _http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'driverId': driverId, 'depot': depot, 'day': day}),
    );
    if (r.statusCode != 200) {
      throw Exception('approve_app failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

    /// POST /admin/add_to_list
  Future<Map<String, dynamic>> addToList({
    required String adminToken,
    required String day,        // yyyy-MM-dd
    required String driverId,
    required String podId,
    String customer = '',
    String address = '',
    String quantity = '',
  }) async {
    final uri = Uri.parse('$base/admin/add_to_list');
    final r = await _http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'day': day,
        'driverId': driverId,
        'podId': podId,
        'customer': customer,
        'address': address,
        'quantity': quantity,
      }),
    );
    if (r.statusCode != 200) {
      throw Exception('Add to list failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ---- Reassign -------------------------------------------------

  /// POST /admin/reassign { day, podId, fromDriverId, toDriverId, reason }
  /// Returns: { mode: "files_move" | "list_only", moved:[], manifestKey, listPatched }
  Future<Map<String, dynamic>> reassign({
    required String adminToken,
    required String day,
    required String podId,
    String? fromDriverId, // nullable
    required String toDriverId,
    String reason = 'handover',
  }) async {
        final uri = Uri.parse('$base/admin/reassign');

    Map<String, dynamic> _baseBody() => {
      'day': day,
      'podId': podId,
      'toDriverId': toDriverId,
      'reason': reason,
    };

    Future<http.Response> _post(Map<String, dynamic> body) {
      return _http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $adminToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
    }

    // 1) First try WITHOUT fromDriverId if it's null/blank (unassigned bucket)
    final hasFrom = fromDriverId != null && fromDriverId.trim().isNotEmpty;
    Map<String, dynamic> body = _baseBody();
    if (hasFrom) body['fromDriverId'] = fromDriverId!.trim();

    var r = await _post(body);

    // 2) If server insists on a value, retry once with 'unknown'
    if (r.statusCode == 400 || r.statusCode == 422) {
      final msg = r.body.toLowerCase();
      final looksLikeFromRequired = msg.contains('fromdriverid') || msg.contains('from driver') || msg.contains('required');
      if (!hasFrom || looksLikeFromRequired) {
// AFTER
        final retry = _baseBody();
        retry['fromDriverId'] = 'unknown';
        r = await _post(retry);
      }
    }

    if (r.statusCode != 200) {
      throw Exception('Reassign failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;

  }

    /// POST /admin/remove_from_list { day, driverId, podId } -> { removed, key, updated }
  Future<Map<String, dynamic>> removeFromList({
    required String adminToken,
    required String day,
    required String driverId,
    required String podId,
  }) async {
    final uri = Uri.parse('$base/admin/remove_from_list');
    final r = await _http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'day': day,
        'driverId': driverId,
        'podId': podId,
      }),
    );
    if (r.statusCode != 200) {
      throw Exception('Remove from list failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ---- PODs listing (for deletes/inspection) --------------------

  /// GET /admin/pods?day=&driverId=  -> { day, driverId, count, podIds, sampleKeys }
  Future<Map<String, dynamic>> pods({
    required String adminToken,
    required String day,
    required String driverId,
  }) async {
    final uri = Uri.parse('$base/admin/pods?day=$day&driverId=$driverId');
    final r = await _http.get(uri, headers: {'Authorization': 'Bearer $adminToken'});
    if (r.statusCode != 200) {
      throw Exception('Pods list failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Convenience: filter keys belonging to a single POD id.
  /// Note: uses `sampleKeys` from /admin/pods; if there are many images,
  /// sampleKeys may be truncated by the server.
  Future<List<String>> listKeysForPod({
    required String adminToken,
    required String day,
    required String driverId,
    required String podId,
  }) async {
    final m = await pods(adminToken: adminToken, day: day, driverId: driverId);
    final all = (m['sampleKeys'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    return all.where((k) => k.contains('/${podId}_')).toList(growable: false);
  }

  // ---- Hard delete ----------------------------------------------

  /// POST /admin/delete { keys:[...] } -> { deleted, errors }
  Future<Map<String, dynamic>> adminDelete({
    required String adminToken,
    required List<String> keys,
  }) async {
    final uri = Uri.parse('$base/admin/delete');
    final r = await _http.post(
      uri,
      headers: {'Authorization': 'Bearer $adminToken', 'Content-Type': 'application/json'},
      body: jsonEncode({'keys': keys}),
    );
    if (r.statusCode != 200) {
      throw Exception('Delete failed (${r.statusCode}): ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}

class AlreadyUploadedPage extends StatelessWidget {
  final PodData pod;
  final String barcode;
  final List<String> imageUrls;
  final VoidCallback onReuploadConfirmed;
  final VoidCallback? onDeleted; // NEW

  const AlreadyUploadedPage({
    super.key,
    required this.pod,
    required this.barcode,
    required this.imageUrls,
    required this.onReuploadConfirmed,
    this.onDeleted, // NEW
  });

Future<void> _deleteAllImages(BuildContext context) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Delete ALL images?'),
      content: Text('This will remove all current images for DO ${pod.podNo} and reset its status.\nProceed?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ),
  );
  if (confirm != true) return;

  try {
    // Derive S3 keys from the shown URLs
    final keys = <String>[];
    for (final url in imageUrls) {
      final uri = Uri.parse(url);
      var segs = List.of(uri.pathSegments);
      if (segs.isNotEmpty && segs.first == 'hm-epod') segs = segs.sublist(1);
      final key = segs.join('/');
      if (key.startsWith('pods/')) keys.add(key);
    }

    // Also delete the manifest to reset status
    final day = _ymdFromRdd(pod.rddDate);
    final driver = pod.transporter.toLowerCase().trim();
    keys.add('pods/$day/$driver/${pod.podNo}_meta.json');

    final sp = await SharedPreferences.getInstance();
    final adminToken = sp.getString(kSpAdminToken) ?? '';
    if (adminToken.isEmpty) throw Exception('admin_login_required');

    final api = AdminApi();
    final out = await api.adminDelete(adminToken: adminToken, keys: keys);

    // Validate result from server
    final errors = (out['errors'] as List?)?.cast<dynamic>() ?? const [];
    if (errors.isNotEmpty) {
      throw Exception('Delete failed for some keys: $errors');
    }

    // Success
    if (onDeleted != null) onDeleted!();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All images deleted.')),
      );
      Navigator.pop(context);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete error: $e')),
      );
    }
  }
}

  @override
  Widget build(BuildContext c) {
  return Scaffold(
    appBar: AppBar(
      centerTitle: true,
      title: const Text('DO Already Uploaded'),
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('📦 DO Number: ${pod.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              Text('🚚 Transporter: ${pod.transporter}', textAlign: TextAlign.center),
              Text('📅 RDD Date: ${pod.rddDate}', textAlign: TextAlign.center),
              Text('🏥 Customer: ${pod.customer}'),
              Text('📍 Address: ${pod.address}', textAlign: TextAlign.center),
              Text('📦 Quantity: ${pod.quantity}', textAlign: TextAlign.center),

              if (imageUrls.isNotEmpty) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: imageUrls.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final url = imageUrls[i];
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            c,
                            MaterialPageRoute(
                              builder: (_) => FullscreenNetworkGalleryPage(
                                urls: imageUrls,
                                initialIndex: i,
                              ),
                            ),
                          );
                        },
                        child: Hero(
                          tag: url,
                          child: SafeNetworkImage(
                            url,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                            radius: BorderRadius.circular(8),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: 320,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  onPressed: onReuploadConfirmed,
                  child: const Text('Reupload Image'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 320,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => _deleteAllImages(c),
                  child: const Text('Delete All Images'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}

// Fullscreen viewer with swipe + pinch-zoom
class FullscreenGalleryPage extends StatefulWidget {
  final List<File> images;
  final int initialIndex;
  const FullscreenGalleryPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  @override
  State<FullscreenGalleryPage> createState() => _FullscreenGalleryPageState();
}

class _FullscreenGalleryPageState extends State<FullscreenGalleryPage> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.images.length}'),
      ),
      body: PageView.builder(
        controller: _pc,
        onPageChanged: (i) => setState(() => _index = i),
        itemCount: widget.images.length,
        itemBuilder: (context, i) {
          final file = widget.images[i];
          return Hero(
            tag: file.path,
            child: InteractiveViewer(
              minScale: 1,           // start at full size
              maxScale: 5,
              clipBehavior: Clip.none,
              child: SizedBox.expand( // make the image take the whole viewport
                child: Image.file(
                  file,
                  fit: BoxFit.contain, // no cropping (black bars if aspect doesn’t match)
                ),
              ),
            ),
          );

        },
      ),
    );
  }
}

// Fullscreen viewer for NETWORK images (URLs)
class FullscreenNetworkGalleryPage extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  const FullscreenNetworkGalleryPage({
    super.key,
    required this.urls,
    this.initialIndex = 0,
  });

  @override
  State<FullscreenNetworkGalleryPage> createState() => _FullscreenNetworkGalleryPageState();
}

class AdminQrPage extends StatelessWidget {
  final String driverId;
  final String day;
  final String token;

  const AdminQrPage({
    super.key,
    required this.driverId,
    required this.day,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    final payload =
    'hmepod://claim?token=${Uri.encodeComponent(token)}&day=$day';

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        // no bullet • in the title as requested
        title: Text('$driverId $day'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // scale QR nicely to screen
          final size = (constraints.biggest.shortestSide * 0.8).clamp(220.0, 420.0);
          return Center(
            child: Container(
              color: Colors.white,              // solid white behind the QR for easier scanning
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                data: payload,
                size: size,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FullscreenNetworkGalleryPageState extends State<FullscreenNetworkGalleryPage> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.urls.length}'),
      ),
      body: PageView.builder(
        controller: _pc,
        onPageChanged: (i) => setState(() => _index = i),
        itemCount: widget.urls.length,
        itemBuilder: (context, i) {
          final url = widget.urls[i];
          return Hero(
            tag: url,
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              clipBehavior: Clip.none,
              child: SizedBox.expand(
                child: SafeNetworkImage(
                  url,
                  fit: BoxFit.contain, // switch to BoxFit.cover if you want full-bleed
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Future<bool> deleteOldPodImages(List<String> keys) async {
  try {
    final sp = await SharedPreferences.getInstance();
    final adminToken = sp.getString(kSpAdminToken) ?? '';
    if (adminToken.isEmpty) throw Exception('admin_login_required');

    final api = AdminApi();
    final out = await api.adminDelete(adminToken: adminToken, keys: keys);
    debugPrint("Deleted: ${out['deleted']}, Errors: ${out['errors']}");
    return true;
  } catch (e) {
    debugPrint('Error deleting images: $e');
    return false;
  }
}

class SafeNetworkImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? radius;

  const SafeNetworkImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final img = Image.network(
      // add a cache-busting param so CDNs don’t serve stale 403s
      url.contains('?') ? '$url&v=1' : '$url?v=1',
      width: width,
      height: height,
      fit: fit,
      // show progress while loading
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return SizedBox(
          width: width, height: height,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
      // never crash on 403/404/etc — show a friendly placeholder
      errorBuilder: (ctx, err, stack) {
        return Container(
          width: width, height: height,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: radius,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.broken_image_outlined),
              SizedBox(height: 4),
              Text('Image unavailable', style: TextStyle(fontSize: 12)),
            ],
          ),
        );
      },
    );

    if (radius != null) {
      return ClipRRect(borderRadius: radius!, child: img);
    }
    return img;

  }
}

