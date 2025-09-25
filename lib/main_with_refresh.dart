import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter/services.dart'; // for Clipboard.copy

const _bucketBase = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com';
// ===== Admin API base =====
const String kApiBase = 'https://s3-upload-api-trvm.onrender.com';
// Used by the driver app to poll for an approval claim
const String kLegacyToken =
    'nrdyMGM8FvTkQ7PAjPy1vEkPNzAQmif4x71JN7TfBZY4xWHEGOeq98JAJb9qhSdm';
// Legacy API token for non-session calls from the app (same token you use for sign/delete)
const String kLegacyApiToken = 'nrdyMGM8FvTkQ7PAjPy1vEkPNzAQmif4x71JN7TfBZY4xWHEGOeq98JAJb9qhSdm';

// ===== SharedPreferences keys =====
const String kSpAdminToken = 'adminToken';
const String kSpAdminTokenExp = 'adminTokenExp'; // optional: epoch ms
// Per-driver session storage (QR unlock) -> sess.token.<driverId>, sess.day.<driverId>
const String kSpSessTokenPrefix = 'sess.token.';
const String kSpSessDayPrefix   = 'sess.day.';

// ---- S3 Daily List Helpers ----
const _listsBase = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com/lists/daily';

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

bool _rowMatchesUser(Map<String, dynamic> row, String username) {
  final u = username.toLowerCase().trim();
  for (final k in ['Driver', 'driver', 'Assigned Driver', 'assigned_driver', 'Username']) {
    if (row.containsKey(k) && (row[k]?.toString().toLowerCase().trim() == u)) {
      return true;
    }
  }
  return false;
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


enum PodStatus { delivered, rejected }

class UploadResult {
  final List<String> urls;
  final PodStatus status;
  UploadResult(this.urls, this.status);
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // keep your theme if you have one
      initialRoute: '/',
      routes: {
        '/': (context) => const BarcodeUploaderApp(),
        '/admin/login': (context) => const AdminLoginPage(),
        '/admin': (context) => const AdminHomePage(),
        // TEMP stub to avoid crash until Step 2 is implemented:
        '/admin/list': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map?;
          final driverId = (args?['driverId'] ?? '').toString();
          final displayName = (args?['displayName'] ?? driverId).toString();
          return AdminListPage(driverId: driverId, displayName: displayName);
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
appBar: AppBar(title: const Text('Admin Login'), centerTitle: true),
body: Padding(
padding: const EdgeInsets.all(16),
child: Column(
crossAxisAlignment: CrossAxisAlignment.stretch,
children: [
const Text('Enter Admin Password'),
const SizedBox(height: 8),
TextField(
controller: _pwd,
obscureText: true,
decoration: const InputDecoration(
border: OutlineInputBorder(),
hintText: '••••••••',
),
onSubmitted: (_) => _submit(),
),
const SizedBox(height: 12),
ElevatedButton(
onPressed: _loading ? null : _submit,
child: _loading
? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
: const Text('Login'),
),
if (_err != null) ...[
const SizedBox(height: 8),
Text(_err!, style: const TextStyle(color: Colors.red)),
],
],
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
                width: 300,
                child: TextField(
                  controller: _usernameController,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 300,
                child: TextField(
                  controller: _passwordController,
                  textAlign: TextAlign.center,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
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
      await _probeApprovedForAll();
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
setState(() { _token = token; _drivers = list; _loading = false; });
    // Probe which drivers already approved today
    _probeApprovedForAll();

} catch (e) {
setState(() { _err = e.toString(); _loading = false; });
}
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
    final claim = 'hmepod://claim?token=$token&day=$day';

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
                    TextButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: claim));
                        Navigator.of(dialogCtx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                      },
                      child: const Text('Copy link'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: () => launchUrlString(claim), child: const Text('Open link')),
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
Navigator.of(context).pushReplacementNamed('/admin/login');
}


@override
Widget build(BuildContext context) {
return Scaffold(
appBar: AppBar(
title: const Text('Admin'),
centerTitle: true,
actions: [
IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),

IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: 'Logout'),
],
),
body: _loading
? const Center(child: CircularProgressIndicator())
: _err != null
? Center(child: Text(_err!))
: RefreshIndicator(onRefresh: _refresh, child: ListView.separated(
itemCount: _drivers.length,
separatorBuilder: (_, __) => const Divider(height: 1),
itemBuilder: (context, i) {
final d = _drivers[i];
final id = (d['driverId'] ?? '').toString();
final name = (d['displayName'] ?? id).toString();
final active = (d['active'] ?? true) == true;
return ListTile(
title: Text(name),
subtitle: Text(id),
trailing: Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    IconButton(
      tooltip: 'Approve today',
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


  // date window (MYT): today to 6 days back
  late DateTime _todayMy;
  late DateTime _fromMy;
  late DateTime _toMy;

  // payload from /admin/list
  List<Map<String, dynamic>> _days = []; // each: { day, rows: [ {row, hasUploads}, ... ] }

  @override
  void initState() {
    super.initState();
    _initDates();
    _load();
  
    _deferProbe();
}
  

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() { _loading = true; });
    try {
      await _load();
      await _probeApprovalToday();
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
      title: const Text('Approve today?'),
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
    try {
      // today in MYT
      final nowUtc = DateTime.now().toUtc();
      final my = nowUtc.add(const Duration(hours: 8));
      final day = DateFormat('yyyy-MM-dd').format(DateTime(my.year, my.month, my.day));

      // mint a driver/day token
      final approve = await AdminApi().approveApp(
        adminToken: _adminToken!,
        driverId: widget.driverId,
        day: day,
      );
      final token = (approve['token'] as String).trim();
      final claim = 'hmepod://claim?token=$token&day=$day';

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
      await sp.setString('$kSpSessTokenPrefix${widget.driverId}', token);
      await sp.setString('$kSpSessDayPrefix${widget.driverId}', day);

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
      final sp = await SharedPreferences.getInstance();
      final at = sp.getString(kSpAdminToken);
      if (at == null || at.isEmpty) {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed('/admin/login');
        return;
      }
      _adminToken = at;

      final api = AdminApi();
      final m = await api.listByDriver(
        adminToken: at,
        driverId: widget.driverId,
        fromYmd: _ymd(_fromMy),
        toYmd: _ymd(_toMy),
      );

      final days = (m['days'] as List?) ?? const [];
      // Normalize: each element becomes {day: 'YYYY-MM-DD', rows: [ {row:<Map>, hasUploads:<bool>} ...]}
      _days = days.map<Map<String, dynamic>>((e) {
        final day = (e['day'] ?? '').toString();
        final rows = (e['rows'] as List? ?? const []).map<Map<String, dynamic>>((r) {
          return {
            'row': Map<String, dynamic>.from(r['row'] as Map),
            'hasUploads': (r['hasUploads'] ?? false) == true,
          };
        }).toList();
        return {'day': day, 'rows': rows};
      }).toList();

      setState(() { _loading = false; });
    } catch (e) {
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

  Future<void> _actionReassign({
    required String day,
    required String fromDriverId,
    required String podId,
  }) async {
    final drivers = await AdminApi().drivers(_adminToken!);
    final items = drivers.map((d) => (d['driverId'] ?? '').toString()).where((id) => id != fromDriverId).toList();

    String? toId = await showModalBottomSheet<String>(
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

    final api = AdminApi();
    final res = await api.reassign(
      adminToken: _adminToken!,
      day: day,
      podId: podId,
      fromDriverId: fromDriverId,
      toDriverId: toId,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res['mode'] == 'list_only'
          ? 'Reassigned in list (no files to move)'
          : 'Files moved & manifest updated')),
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
        title: const Text('Remove from list?'),
        content: Text('This will remove POD $podId from $driverId on $day.\n'
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
    // Build the selectable days using the same window you display (from -> to)
    final days = <String>[];
    for (var d = _fromMy; !d.isAfter(_toMy); d = d.add(const Duration(days: 1))) {
      days.add(DateFormat('yyyy-MM-dd').format(d));
    }
    String day = DateFormat('yyyy-MM-dd').format(_toMy); // default = today

    final podCtrl  = TextEditingController();
    final custCtrl = TextEditingController();
    final addrCtrl = TextEditingController();
    final qtyCtrl  = TextEditingController();
    final formKey  = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Add POD • ${widget.displayName}'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: day,
                  items: days.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                  onChanged: (v) => day = v ?? day,
                  decoration: const InputDecoration(labelText: 'Day (YYYY-MM-DD)'),
                ),
                TextFormField(
                  controller: podCtrl,
                  decoration: const InputDecoration(labelText: 'POD No'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: custCtrl,
                  decoration: const InputDecoration(labelText: 'Customer (optional)'),
                ),
                TextFormField(
                  controller: addrCtrl,
                  decoration: const InputDecoration(labelText: 'Address (optional)'),
                ),
                TextFormField(
                  controller: qtyCtrl,
                  decoration: const InputDecoration(labelText: 'Quantity (optional)'),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(context, true);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (ok != true) { 
      podCtrl.dispose(); custCtrl.dispose(); addrCtrl.dispose(); qtyCtrl.dispose();
      return;
    }

    try {
      final api = AdminApi();
      await api.addToList(
        adminToken: _adminToken!,
        day: day,
        driverId: widget.driverId,
        podId: podCtrl.text.trim(),
        customer: custCtrl.text.trim(),
        address: addrCtrl.text.trim(),
        quantity: qtyCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added POD ${podCtrl.text.trim()} to $day')),
      );
      await _load(); // refresh UI
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Add failed: $e')),
      );
    } finally {
      podCtrl.dispose(); custCtrl.dispose(); addrCtrl.dispose(); qtyCtrl.dispose();
    }
  }


  @override
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
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(child: Text(_err!))
              : RefreshIndicator(onRefresh: _refresh, child: ListView.builder(
                  itemCount: _days.length,
                  itemBuilder: (context, i) {
                    final day = _days[i]['day'] as String;
                    final rows = (_days[i]['rows'] as List).cast<Map<String, dynamic>>();
                    if (rows.isEmpty) {
                      return ListTile(
                        title: Text(day),
                        subtitle: const Text('No rows'),
                      );
                    }
                    return ExpansionTile(
                      title: Text(day),
                      subtitle: Text('${rows.length} item(s)'),
                      children: [
                        for (final r in rows) _rowTile(day, driverId, r),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _rowTile(String day, String driverId, Map<String, dynamic> entry) {
    final row = entry['row'] as Map<String, dynamic>;
    final has = (entry['hasUploads'] ?? false) == true;
    final podId = _podIdOfRow(row);
    final customer = _customerOfRow(row);

    return ListTile(
      dense: true,
      title: Text(podId.isEmpty ? '(no POD id)' : podId),
      subtitle: Text(customer),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(has ? Icons.check_circle : Icons.radio_button_unchecked,
              color: has ? Colors.green : Colors.grey),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'reassign') {
                await _actionReassign(day: day, fromDriverId: driverId, podId: podId);
              } else if (v == 'upload') {
                await _actionUploadOnBehalf(day: day, driverId: driverId, row: row);
              } else if (v == 'remove') {
                await _actionRemoveFromList(day: day, driverId: driverId, podId: podId);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reassign', child: Text('Reassign…')),
              PopupMenuItem(value: 'upload',   child: Text('Upload on behalf…')),
              PopupMenuItem(value: 'remove',   child: Text('Remove from list…')),
            ],
          ),
        ],
      ),
    );
  }
}


class BarcodeUploaderApp extends StatefulWidget {
  const BarcodeUploaderApp({super.key});
  @override
  State<BarcodeUploaderApp> createState() => _BarcodeUploaderAppState();
}

class _BarcodeUploaderAppState extends State<BarcodeUploaderApp> {
  String? barcode;
  String? loggedInUsername;
  bool showScanner = false;
  Set<String> uploadedPods = {};
  Set<String> rejectedPods = {};
  List<PodData> podDataList = [];
  String? sessionToken;   // JWT from secure QR/admin
  String? sessionDay;     // YYYY-MM-DD (MYT) for which the token is valid
  PodData? podDetails;
  bool isUploading = false;

  // Store uploaded image URLs by POD number
  final Map<String, List<String>> podImages = {};
  final Map<String, List<File>> podImageFiles = {};
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processingScan = false;
  Future<void> _loadSessionForUser(String username) async {
  final sp = await SharedPreferences.getInstance();
  final tok = sp.getString('$kSpSessTokenPrefix$username');
  final day = sp.getString('$kSpSessDayPrefix$username');
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
  loadSavedLogin().then((_) async {
    if (loggedInUsername != null) {
      await _tryAutoClaimToday();                 // <— NEW: auto-claim first
      await loadPodDataFromS3ForUser(loggedInUsername!);
    }
  });
}

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

Future<void> _tryAutoClaimToday() async {
  if (loggedInUsername == null) return;
  final day = _todayYMD();
  try {
    final r = await http.post(
      Uri.parse('$kApiBase/claim_poll'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $kLegacyToken',
      },
      body: jsonEncode({
        'driverId': loggedInUsername!.toLowerCase().trim(),
        'day': day,
      }),
    );

    if (r.statusCode == 200) {
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final t = (m['token'] ?? '').toString();
      final d = (m['day'] ?? '').toString();
      if (t.isNotEmpty && d.isNotEmpty) {
        setState(() {
          sessionToken = t;
          sessionDay = d;
        });
      }
    }
  } catch (_) {/* ignore network errors */}
}


Future<void> _checkApprovalNow() async {
  if (loggedInUsername == null) return;
  final uri = Uri.parse('$kApiBase/claim_poll');
  final day = _todayYMD();
  try {
    final r = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $kLegacyApiToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'driverId': loggedInUsername!, 'day': day}),
    );

    if (r.statusCode == 200) {
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      final token = (m['token'] as String?)?.trim();
      final gotDay = (m['day'] as String?)?.trim();
      if (token != null && gotDay != null) {
        setState(() {
          sessionToken = token;
          sessionDay = gotDay;
        });
        await loadPodDataFromS3ForUser(loggedInUsername!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Today unlocked via approval')),
          );
        }
        return;
      }
    }

    // Not approved yet
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not approved yet for $day')),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Check failed: $e')),
      );
    }
  }
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

  Future<void> loadPodDataFromS3ForUser(String username) async {
    setState(() {
      podDataList = [];
      uploadedPods.clear();
      rejectedPods.clear();
      podImages.clear();
    });

    final includeToday = (sessionToken != null && sessionDay == _todayYMD());

    debugPrint('includeToday=$includeToday  sessionDay=$sessionDay  today=${_todayYMD()}');

    // Build date list: today (optional) + last 6 days
    final now = _todayMY();
    final dates = <DateTime>[];
    if (includeToday) dates.add(DateTime(now.year, now.month, now.day));
    for (int i = 1; i <= 6; i++) {
      final d = now.subtract(Duration(days: i));
      dates.add(DateTime(d.year, d.month, d.day));
    }

    // Merge rows across days, cap 100, newest wins for duplicates
    final Map<String, Map<String, dynamic>> byPod = {}; // POD -> row
    int total = 0;

    for (final day in dates) {
      if (total >= 100) break;

      final candidates = _candidateDailyListUrls(day);
      List<dynamic>? rows;
      for (final url in candidates) {
        try {
          final res = await http.get(url);
          if (res.statusCode == 200) { rows = jsonDecode(utf8.decode(res.bodyBytes)); break; }
        } catch (_) {}
      }
      if (rows == null) continue;

      final filtered = rows.where((row) {
        final m = row as Map<String, dynamic>;
        if (!_rowMatchesUser(m, username)) return false;

        // hide “today” rows until a session is unlocked (via secure QR)
        if (!(sessionToken != null && sessionDay == _todayYMD())) {
          final rddYmd = _ymdFromRdd((m['RDD Date'] ?? '').toString());
          if (rddYmd == _todayYMD()) return false;
        }
        return true;
      });

      for (final e in filtered) {
        final m = e as Map<String, dynamic>;
        final pod = (m['POD No'] ?? m['POD'] ?? m['pod'] ?? '').toString().trim();
        if (pod.isEmpty) continue;
        if (!byPod.containsKey(pod)) { // first time we see this POD = newest day
          byPod[pod] = Map<String, dynamic>.from(m);
          total++; if (total >= 100) break;
        }
      }
    }

    // Materialize and sort by RDD desc (so 'firstWhere' prefers newest/today)
    final out = byPod.values.map((m) => PodData.fromJson(m)).toList();
    DateTime p(String s) {
      try { return DateFormat('dd/MM/yy').parse(s); } catch (_) {}
      try { return DateFormat('dd/MM/yyyy').parse(s); } catch (_) {}
      return DateTime(1970,1,1);
    }
    out.sort((a,b) => p(b.rddDate).compareTo(p(a.rddDate)));

    setState(() { podDataList = out; });

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

  Future<void> openUploadPage(bool isRejected) async {
    if (barcode == null || podDetails == null) return;

    // Capture the selected POD info BEFORE awaiting
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

    setState(() {
      podImages[selectedPodNo] = result.urls;

      if (result.status == PodStatus.rejected) {
        rejectedPods.add(selectedPodNo);
        uploadedPods.remove(selectedPodNo);
      } else {
        uploadedPods.add(selectedPodNo);
        rejectedPods.remove(selectedPodNo);
      }

      // Clear detail state
      barcode = null;
      podDetails = null;
    });
    await _hydrateFromS3Manifests();
  }

  Future<Map<String, dynamic>?> _fetchPodManifest(PodData pod) async {
    final dayStr = _ymdFromRdd(pod.rddDate);
    final user = loggedInUsername ?? '';
    final uri = Uri.parse('$_bucketBase/pods/$dayStr/$user/${pod.podNo}_meta.json?v=${DateTime.now().millisecondsSinceEpoch}');
    try {
      final res = await http.get(uri);
      if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (res.statusCode == 404 || res.statusCode == 403) return null;
      debugPrint('Manifest ${pod.podNo} unexpected ${res.statusCode}: ${res.body}');
      return null;
    } catch (e) {
      debugPrint('Manifest fetch failed for ${pod.podNo}: $e');
      return null;
    }
  }

  Future<void> _hydrateFromS3Manifests() async {
    uploadedPods.clear();
    rejectedPods.clear();
    podImages.clear();

    final futures = <Future<void>>[];
    for (final pod in podDataList) {
      futures.add(() async {
        final data = await _fetchPodManifest(pod);
        if (data == null) return;
        final status = (data['status'] as String?) ?? '';
        final urls = (data['urls'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
        // mutate shared maps/sets — do in the main isolate but it’s fine here
        podImages[pod.podNo] = urls;
        if (status == 'delivered') {
          uploadedPods.add(pod.podNo);
        } else if (status == 'rejected') {
          rejectedPods.add(pod.podNo);
        }
      }());
    }

    await Future.wait(futures);
    if (mounted) setState(() {});
  }

  List<Object> _groupedItemsByDay(List<PodData> items) {
    final byDay = <String, List<PodData>>{};
    for (final p in items) { (byDay[p.rddDate] ??= []).add(p); }

    DateTime _looseParseDate(String s) {
      s = (s ?? '').toString().trim();
      for (final fmt in [
        'dd/MM/yy',
        'dd/MM/yyyy',
        'yyyy-MM-dd',
        'yyyy-MM-dd HH:mm:ss',
      ]) {
        try { return DateFormat(fmt).parse(s); } catch (_) {}
      }
      // ISO fallback
      try { return DateTime.parse(s); } catch (_) {}
      return DateTime(1970, 1, 1);
    }

    final ordered = byDay.keys.toList()
      ..sort((a, b) => _looseParseDate(b).compareTo(_looseParseDate(a)));

    final out = <Object>[];
    for (final d in ordered) {
      out.add({'header': d, 'count': byDay[d]!.length});
      out.addAll(byDay[d]!);
    }
    return out;
  }


  @override
  Widget build(BuildContext context) {
    
    if (loggedInUsername == null) {
      return LoginPage(
        onLoginSuccess: (username) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('loggedInUsername', username);
          setState(() => loggedInUsername = username);
          // hydrate session (if admin already approved on this device)
          await _loadSessionForUser(username);
          await loadPodDataFromS3ForUser(username);
        },
      );
    }

    final today = DateFormat('dd/MM/yyyy').format(DateTime.now());

    if (showScanner) {
      
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => showScanner = false),
          ),
          title: const Text('Scan QR / POD'),
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
                      await sp.setString('$kSpSessTokenPrefix${loggedInUsername!}', t);
                      await sp.setString('$kSpSessDayPrefix${loggedInUsername!}', d);
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
                      await sp.setString('$kSpSessTokenPrefix${loggedInUsername!}', t);
                      await sp.setString('$kSpSessDayPrefix${loggedInUsername!}', d);
                    }
                    await loadPodDataFromS3ForUser(loggedInUsername!);
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Today unlocked')));
                    _processingScan = false;
                    return;
                  }
                } catch (_) {}
              }
              // 2) Otherwise, treat as POD barcode (numeric/partial numeric)

              final int? num = int.tryParse(code);
              if (num == null) return;

              final match = podDataList.firstWhere(
                (e) {
                  final podDigits = (e.podNo ?? '').replaceAll(RegExp(r'\D'), '');
                  final scanDigits = (code ?? '').replaceAll(RegExp(r'\D'), '');

                  if (podDigits.isEmpty || scanDigits.isEmpty) return false;

                  // Decide match length
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
                },
                orElse: PodData.empty,
              );

              if (match.podNo.isEmpty) return;

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
                            title: const Text('Confirm Reupload'),
                            content: Text('This POD already has $count image(s). Replace them?'),
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
  return PopScope(
    canPop: false,
    onPopInvoked: (didPop) {
      if (!didPop) {
        setState(() {
          barcode = null;
          podDetails = null;
        });
      }
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
        title: Text('POD ${podDetails!.podNo}'),
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
          Text('📦 POD Number: ${podDetails!.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          Text('🏥 Customer: ${podDetails!.customer}', textAlign: TextAlign.center),
          Text('🔢 Quantity: ${podDetails!.quantity}', textAlign: TextAlign.center),
          Text('🚚 Transporter: ${podDetails!.transporter}', textAlign: TextAlign.center),

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
          // Admin entry
          IconButton(
            icon: const Icon(Icons.admin_panel_settings),
            tooltip: 'Admin',
            onPressed: () => Navigator.of(context).pushNamed('/admin/login'),
          ),
          // Existing logout
          IconButton(icon: const Icon(Icons.logout), tooltip: 'Logout', onPressed: logout),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Text('Weekly View', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            const SizedBox(height: 16),
            // Today locked banner (shows until a valid sessionToken for today's day exists)
            if (!(sessionToken != null && sessionDay == _todayYMD())) ...[
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
                          onPressed: () => setState(() => showScanner = true),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _checkApprovalNow,          // <-- no-QR approval fetch
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Check'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Expanded(
              child: RefreshIndicator(
                  onRefresh: () async {
                    if (loggedInUsername != null) {
                      await _tryAutoClaimToday();                   // <— NEW
                      await loadPodDataFromS3ForUser(loggedInUsername!);
                    } else {
                      await _hydrateFromS3Manifests();
                    }
                  },
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _groupedItemsByDay(podDataList).length,
                    itemBuilder: (c, i) {
                      final obj = _groupedItemsByDay(podDataList)[i];
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
                                        title: const Text('Confirm Reupload'),
                                        content: Text('This POD already has $count image(s). Replace them?'),
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
                                : Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('📦 POD: ${pod.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text('🏥 Customer: ${pod.customer}', textAlign: TextAlign.center),
                              Text('🔢 Qty: ${pod.quantity}', textAlign: TextAlign.center),
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
      floatingActionButton: FloatingActionButton(onPressed: () => setState(() => showScanner = true), child: const Icon(Icons.camera_alt)),
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

  static const _apiToken = 'nrdyMGM8FvTkQ7PAjPy1vEkPNzAQmif4x71JN7TfBZY4xWHEGOeq98JAJb9qhSdm';
  Map<String,String> _headersForKey(String contentType, String key) {
    final String? sd = widget.sessionDay;
    final bool canUseJwt = (widget.sessionToken != null) &&
                          sd != null &&
                          key.startsWith('pods/$sd/');
    return {
      'Content-Type': contentType,
      'Authorization': canUseJwt
          ? 'Bearer ${widget.sessionToken!}'
          : 'Bearer $_apiToken',
    };
  }
  final List<File> images = [];
  final picker = ImagePicker();
  bool isUploading = false;

  Future<void> pickImage() async {
    final XFile? img = await picker.pickImage(source: ImageSource.camera);
    if (!mounted) return;
    if (img != null) setState(() => images.add(File(img.path)));
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

  setState(() => isUploading = true);
  try {
    List<String> urls = [];

    for (int i = 0; i < images.length; i++) {
      final String podNoFull = widget.podData.podNo;
      final String dayStr    = _ymdFromRdd(widget.podData.rddDate);
      final key = 'pods/$dayStr/${widget.username}/${podNoFull}_${i + 1}.jpg';
      final payload = jsonEncode({'filename': key, 'contentType': 'image/jpeg'});

      final presign = await http.post(
        Uri.parse(_signEndpoint),
        headers: _headersForKey('application/json', key),
        body: payload,
      );

      if (presign.statusCode != 200) {
        logError('sign', presign);
      }

      final url = jsonDecode(presign.body)['url'] as String;

      // Derive S3 key for stable public URL
      final uri = Uri.parse(url);
      List<String> segs = List.of(uri.pathSegments);
      if (segs.isNotEmpty && segs.first == 'hm-epod') {
        segs = segs.sublist(1);
      }
      final finalKey = segs.join('/');
      final viewUrl = 'https://hm-epod.s3.ap-southeast-1.amazonaws.com/$finalKey';

      final putRes = await http.put(
        Uri.parse(url),
        headers: {'Content-Type': 'image/jpeg'},
        body: await images[i].readAsBytes(),
      );

      if (putRes.statusCode != 200) {
        logError('putImage', putRes);
      }

      if (putRes.statusCode == 200) {
        urls.add(viewUrl);
      } else {
        debugPrint('Failed to upload image ${i + 1}');
      }
  }

  // Discord notification
// Discord notification via server
  final statusLine = widget.isRejected ? '❌ Rejected' : '✅ Delivered';
  final msg = '''📦 POD Number: ${widget.podData.podNo}
  $statusLine
  🚚 ${widget.podData.transporter}
  📅 ${widget.podData.rddDate}
  🏥 ${widget.podData.customer}
  📍 ${widget.podData.address}
  📦 ${widget.podData.quantity}
  ''';

  final dayStrNotify = _ymdFromRdd(widget.podData.rddDate);
  final anyKeyForAuth = 'pods/$dayStrNotify/${widget.username}/${widget.podData.podNo}_1.jpg';
  final notifyRes = await http.post(
    Uri.parse('https://s3-upload-api-trvm.onrender.com/notify'),
    headers: _headersForKey('application/json', anyKeyForAuth),
    body: jsonEncode({
      'content': msg,
      'imageUrls': urls,
    }),
  );

  if (notifyRes.statusCode != 200) {
    logError('notify', notifyRes);
  }

  // Remove old images if needed
  final int newCount = urls.length;
  final int oldCount = widget.previousCount;
  if (oldCount > newCount) {
    final String podNoFull = widget.podData.podNo;
    final String dayStr2   = _ymdFromRdd(widget.podData.rddDate);
    final excessKeys = List.generate(
      oldCount - newCount,
      (i) => 'pods/$dayStr2/${widget.username}/${podNoFull}_${newCount + i + 1}.jpg',
    );
    final ok = await deleteOldPodImages(excessKeys);
    if (!ok) {
      debugPrint('Warning: failed to delete extra old keys: $excessKeys');
    }
  }

  if (!mounted) return;
  await _writeManifestToS3(urls);

  Navigator.pop(
    context,
    UploadResult(
      urls,
      widget.isRejected ? PodStatus.rejected : PodStatus.delivered,
    ),
  );
} finally {
  if (mounted) {
    setState(() => isUploading = false);
  }
}
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
  }

  final signedUrl = jsonDecode(presignRes.body)['url'] as String;

  final putRes = await http.put(
    Uri.parse(signedUrl),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(manifest),
  );

  if (putRes.statusCode != 200) {
    logError('putManifest', putRes);
  }

}

  @override
Widget build(BuildContext c) {
    final pd = widget.podData;

    return PopScope(
      // When false, system back/gesture pop is blocked.
      canPop: !isUploading,
      onPopInvoked: (didPop) {
        // Optional: you can show a toast/snackbar if user tries to back out
        // while uploading. This only runs when a pop was attempted.
        if (!didPop && isUploading) {
          ScaffoldMessenger.of(c).showSnackBar(
            const SnackBar(content: Text('Please wait, uploading...')),
          );
        }
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
              Text('📦 POD Number: ${pd.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
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
                    return GestureDetector(
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

  

  /// POST /claim_poll -> returns 200 if a claim exists for {driverId, day}
  Future<bool> claimExists({required String driverId, required String day}) async {
    final uri = Uri.parse('$base/claim_poll');
    try {
      final r = await _http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $kLegacyApiToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'driverId': driverId, 'day': day}),
      );
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
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
    required String fromDriverId,
    required String toDriverId,
    String reason = 'handover',
  }) async {
    final uri = Uri.parse('$base/admin/reassign');
    final r = await _http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $adminToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'day': day,
        'podId': podId,
        'fromDriverId': fromDriverId,
        'toDriverId': toDriverId,
        'reason': reason,
      }),
    );
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
  const AlreadyUploadedPage({super.key, required this.pod, required this.barcode, required this.imageUrls, required this.onReuploadConfirmed});
  @override
Widget build(BuildContext c) {
  return Scaffold(
    appBar: AppBar(
      centerTitle: true,
      title: const Text('POD Already Uploaded'),
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
              Text('📦 POD Number: ${pod.podNo}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              Text('🚚 Transporter: ${pod.transporter}', textAlign: TextAlign.center),
              Text('📅 RDD Date: ${pod.rddDate}', textAlign: TextAlign.center),
              Text('🏥 Customer: ${pod.customer}', textAlign: TextAlign.center),
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
  const AdminQrPage({super.key, required this.driverId, required this.day, required this.token});

  @override
  Widget build(BuildContext context) {
    final payload = jsonEncode({'token': token, 'day': day});
    return Scaffold(
      appBar: AppBar(title: Text('QR for $driverId • $day'), centerTitle: true),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: payload, size: 280),
            const SizedBox(height: 16),
            const Text('Driver scans this to unlock “today”.'),
            const SizedBox(height: 8),
            SelectableText(payload, textAlign: TextAlign.center),
          ],
        ),
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
  const String deleteUrl = 'https://s3-upload-api-trvm.onrender.com/delete';
  
  try {
    final response = await http.post(
      Uri.parse(deleteUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer nrdyMGM8FvTkQ7PAjPy1vEkPNzAQmif4x71JN7TfBZY4xWHEGOeq98JAJb9qhSdm',
      },
      body: jsonEncode({'keys': keys}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      print("Deleted: ${data['deleted']}");
      print("Errors: ${data['errors']}");
      return true;
    } else {
      print('Failed to delete images: ${response.body}');
      return false;
    }
  } catch (e) {
    print('Error deleting images: $e');
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

