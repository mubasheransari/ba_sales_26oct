import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:ords_ba/Api_config/api_config.dart';
import 'package:ords_ba/Model/complaint_models.dart';
import 'package:ords_ba/Model/dashboard_models.dart';
import 'package:ords_ba/Data/device_id.dart';
import 'package:ords_ba/Model/models.dart';
import 'package:ords_ba/Model/review_models.dart';

/// Thrown for any failed API call. [message] is safe to show to the user.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, [this.statusCode]);

  /// Only 401 means the login (session) is no longer valid.
  /// 403 just means "you are not allowed to do this" (for example a location
  /// that is not assigned to you) and must NOT sign the BA out.
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

class LoginResult {
  final String token;
  final AppUser user;
  const LoginResult(this.token, this.user);
}

/// Every network call of the BA module lives here.
class Repository {
  Repository({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /* ----------------------------- helpers ----------------------------- */

  Map<String, String> _headers({String? token, bool json = true}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        // The server links a BA account to the phone it was registered on.
        if (DeviceId.isReady) 'X-Device-Id': DeviceId.value,
      };

  dynamic _tryDecode(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  String? _messageOf(dynamic data) {
    if (data is Map) {
      for (final k in ['message', 'error', 'msg', 'detail', 'error_message']) {
        final v = data[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      // ORDS error shape: {"code": "...", "message": "..."} handled above.
      final nested = data['data'];
      if (nested is Map) return _messageOf(nested);
    }
    if (data is String && data.trim().isNotEmpty) return data;
    return null;
  }

  /// Sends a request, decodes the JSON and converts every kind of failure
  /// (HTTP error, `success:false`, no internet, timeout) into [ApiException].
  Future<dynamic> _send(Future<http.Response> Function() call,
      {Duration? timeout}) async {
    http.Response res;
    try {
      res = await call().timeout(timeout ?? ApiConfig.timeout);
    } on SocketException {
      throw const ApiException('No internet connection. Please try again.');
    } on TimeoutException {
      throw const ApiException('Server took too long to respond. Try again.');
    } on http.ClientException {
      throw const ApiException('Could not reach the server. Try again.');
    }

    final data = _tryDecode(utf8.decode(res.bodyBytes));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final fallback = switch (res.statusCode) {
        401 => 'Session expired. Please login again.',
        403 => 'You are not allowed to do this.',
        404 => 'Service not found (404).',
        _ => 'Request failed (${res.statusCode}).',
      };
      throw ApiException(_messageOf(data) ?? fallback, res.statusCode);
    }

    // Some ORDS handlers answer 200 with a failure flag in the body.
    if (data is Map) {
      final success = data['success'];
      final status = data['status']?.toString().toLowerCase();
      final failed = success == false ||
          success?.toString().toLowerCase() == 'false' ||
          status == 'error' ||
          status == 'fail' ||
          status == 'failed';
      if (failed) {
        throw ApiException(
            _messageOf(data) ?? 'Request failed.', res.statusCode);
      }
    }
    return data;
  }

  /// Unwraps common response wrappers (`data`, `user`, `profile`, `result`),
  /// descending until the innermost user-like map is reached.
  Map<String, dynamic>? _findMap(dynamic data, [int depth = 0]) {
    if (data is! Map) return null;
    if (depth < 3) {
      for (final k in ['user', 'profile', 'data', 'result']) {
        final v = data[k];
        if (v is Map) return _findMap(v, depth + 1);
      }
    }
    return Map<String, dynamic>.from(data);
  }

  String? _findToken(dynamic data) {
    if (data is Map) {
      for (final k in [
        'token',
        'access_token',
        'auth_token',
        'session_token',
        'bearer_token',
      ]) {
        final v = data[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      for (final k in ['data', 'result', 'user']) {
        final t = _findToken(data[k]);
        if (t != null) return t;
      }
    }
    return null;
  }

  /// Reads an ORDS collection (`items` + `next.$ref` paging) fully.
  Future<List<Map<String, dynamic>>> _getAll(String firstUrl,
      {String? token}) async {
    final out = <Map<String, dynamic>>[];
    final seenUrls = <String>{};
    String? url = firstUrl;
    var guard = 0;

    while (url != null && seenUrls.add(url) && guard++ < 100) {
      final data = await _send(
          () => _client.get(Uri.parse(url!), headers: _headers(token: token, json: false)));

      List? items;
      if (data is List) {
        items = data;
      } else if (data is Map) {
        items = (data['items'] ?? data['data'] ?? data['results']) as List?;
      }
      for (final e in items ?? const []) {
        if (e is Map) out.add(Map<String, dynamic>.from(e));
      }

      String? next;
      if (data is Map) {
        final n = data['next'];
        if (n is Map && n[r'$ref'] != null) next = n[r'$ref'].toString();
        if (data['hasMore'] == false) next = null;
      }
      if ((items ?? const []).isEmpty) next = null;
      url = next;
    }
    return out;
  }

  /* ------------------------------ locations ------------------------------ */

  

Future<List<MartLocation>> fetchLocations() async {
  final response = await http.get(
    Uri.parse('http://tapex.mezangrp.com/ords/hrms/ba-sales-v2/locations/list/'),
    headers: {
      'Accept': 'application/json',
    },
  );

  if (response.statusCode != 200) {
    throw ApiException(
      'Failed to load locations. HTTP ${response.statusCode}',
    );
  }

final Map<String, dynamic> data = jsonDecode(response.body);

if (data['success'] != true) {
  throw Exception(
    data['message']?.toString() ?? 'Failed to fetch locations',
  );
}

final List<dynamic> items = data['locations'] as List<dynamic>? ?? [];

return items.map((item) {
  return MartLocation.fromJson(
    Map<String, dynamic>.from(item as Map),
  );
}).toList();
}

  /* -------------------------------- auth -------------------------------- */

  Future<String> signup({
    required String fullName,
    required String email,
    required String cnic,
    required String password,
    required String confirmPassword,
    required int locationId,
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.signup),
          headers: _headers(),
          body: jsonEncode({
            'full_name': fullName,
            'email': email,
            'cnic': cnic,
            'password': password,
            'confirm_password': confirmPassword,
            'role': 'BA',
            'location_id': locationId,
            'device_id': DeviceId.value,
          }),
        ));
    return _messageOf(data) ?? 'Account created. Please login.';
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.login),
          headers: _headers(),
          body: jsonEncode({
            'email': email,
            'password': password,
            'device_id': DeviceId.value,
          }),
        ));

    final token = _findToken(data);
    if (token == null) {
      throw const ApiException('Login succeeded but no token was returned.');
    }
    final map = _findMap(data) ?? {};
    final user = AppUser.fromJson(map);
    return LoginResult(
      token,
      user.email.isEmpty ? user.mergeWith(AppUser(id: '', fullName: 'BA', email: email)) : user,
    );
  }

  /// Asks the server whether [email] may be used on this phone.
  /// Never throws: if the server cannot answer, the login is simply tried
  /// (the server still refuses a wrong phone by itself).
  ///
  /// [signup] true: the question is "may a NEW account be created on this
  /// phone?" (a phone can only have one account).
  Future<DeviceCheck> checkDevice({
    required String email,
    bool signup = false,
  }) async {
    try {
      final data = await _send(() => _client.post(
            Uri.parse(ApiConfig.deviceCheck),
            headers: _headers(),
            body: jsonEncode({
              'email': email,
              'device_id': DeviceId.value,
              'mode': signup ? 'signup' : 'login',
            }),
          ));
      if (data is Map && data['allowed'] == false) {
        return DeviceCheck(
          false,
          '${data['message'] ?? 'This account is registered on another device.'}',
        );
      }
    } catch (_) {
      // not available: continue with the normal login
    }
    return const DeviceCheck(true, '');
  }

  /// Links the account to this phone. Used right after sign up (no token
  /// yet; the server allows it for a brand-new account) and after a login
  /// (with the token). Never throws. Returns null when the phone is linked,
  /// otherwise the reason (so the app can show it).
  Future<String?> bindDevice({String? token, required String email}) async {
    try {
      final data = await _send(() => _client.post(
            Uri.parse(ApiConfig.deviceBind),
            headers: _headers(token: token),
            body: jsonEncode({'email': email, 'device_id': DeviceId.value}),
          ));
      if (data is Map && data['bound'] == false) {
        return '${data['message'] ?? 'not linked'}';
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'no answer from the server';
    }
  }

  Future<AppUser> fetchProfile(String token) async {
    final data = await _send(() => _client.get(
          Uri.parse(ApiConfig.profile),
          headers: _headers(token: token, json: false),
        ));
    final map = _findMap(data);
    if (map == null) throw const ApiException('Could not read profile.');
    return AppUser.fromJson(map);
  }

  /* ----------------------------- attendance ----------------------------- */

  Future<String> attendanceIn({
    required String token,
    required double latitude,
    required double longitude,
    required int locationId,
    required Uint8List selfie,
  }) =>
      _attendance(ApiConfig.attendanceIn, token, latitude, longitude, locationId,
          'Attendance IN marked.',
          extra: {
            'selfie_base64': base64Encode(selfie),
            'selfie_mime': 'image/jpeg',
          });

  Future<String> attendanceOut({
    required String token,
    required double latitude,
    required double longitude,
    required int locationId,
    required Uint8List selfie,
    required Uint8List shelf,
  }) =>
      _attendance(ApiConfig.attendanceOut, token, latitude, longitude, locationId,
          'Attendance OUT marked.',
          extra: {
            'selfie_base64': base64Encode(selfie),
            'selfie_mime': 'image/jpeg',
            'shelf_base64': base64Encode(shelf),
            'shelf_mime': 'image/jpeg',
          });

  Future<String> _attendance(String url, String token, double lat, double lng,
      int locationId, String fallback,
      {Map<String, dynamic> extra = const {}}) async {
    final data = await _send(
      () => _client.post(
        Uri.parse(url),
        headers: _headers(token: token),
        body: jsonEncode({
          'latitude': lat,
          'longitude': lng,
          'location_id': locationId,
          ...extra,
        }),
      ),
      timeout: ApiConfig.uploadTimeout,
    );
    return _messageOf(data) ?? fallback;
  }

  /* -------------------------------- sales -------------------------------- */

  /// Active SKUs only (inactive ones are skipped).
  Future<List<Sku>> fetchSkus() async {
    final rows = await _getAll(ApiConfig.skuList);
    final seen = <int>{};
    final out = <Sku>[];
    for (final r in rows) {
      if (!Sku.isActive(r)) continue;
      final s = Sku.fromJson(r);
      if (s.skuId == 0 || !seen.add(s.skuId)) continue;
      out.add(s);
    }
    out.sort((a, b) {
      final g = a.group.toLowerCase().compareTo(b.group.toLowerCase());
      return g != 0 ? g : a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
    });
    return out;
  }

  Future<String> enterSales({
    required String token,
    required int locationId,
    required String saleDate, // yyyy-MM-dd
    required Map<int, int> quantities, // sku_id -> qty
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.enterSales),
          headers: _headers(token: token),
          body: jsonEncode({
            'location_id': locationId,
            'sale_date': saleDate,
            'items': [
              for (final e in quantities.entries)
                {'sku_id': e.key, 'quantity': e.value},
            ],
          }),
        ));
    return _messageOf(data) ?? 'Sales saved.';
  }

  /* --------------------------- shelf picture --------------------------- */

  /// POST { user_id, location_id, latitude, longitude, file_name,
  ///        image_mime, remarks, image_base64 }
  /// Success: HTTP 201 {"status":"success","id":1}  -> returns the id.
  Future<String> uploadShelfPicture({
    required String token,
    required int userId,
    required int locationId,
    required double latitude,
    required double longitude,
    required String fileName,
    required Uint8List bytes,
    String remarks = '',
  }) async {
    final lower = fileName.toLowerCase();
    final mime = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';

    final data = await _send(
      () => _client.post(
        Uri.parse(ApiConfig.shelfUpload),
        headers: _headers(token: token),
        body: jsonEncode({
          'user_id': userId,
          'location_id': locationId,
          'latitude': latitude,
          'longitude': longitude,
          'file_name': fileName,
          'image_mime': mime,
          'remarks': remarks,
          'image_base64': base64Encode(bytes), // no line breaks
        }),
      ),
      timeout: ApiConfig.uploadTimeout,
    );
    if (data is Map && data['id'] != null) return data['id'].toString();
    return '';
  }

  /* ----------------------------- low stock ----------------------------- */

  /// POST { user_id, location_id,
  ///        items: [ { sku_id, question_ids: [ ... ] } ] }
  /// [questionsBySku] holds the review questions ticked for each product.
  Future<String> submitLowStock({
    required String token,
    required int userId,
    required int locationId,
    required List<int> skuIds,
    Map<int, List<int>> questionsBySku = const {},
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.lowStockSubmit),
          headers: _headers(token: token),
          body: jsonEncode({
            'user_id': userId,
            'location_id': locationId,
            'items': [
              for (final id in skuIds)
                {
                  'sku_id': id,
                  'question_ids': questionsBySku[id] ?? const <int>[],
                },
            ],
          }),
        ));
    if (data is Map && data['id'] != null) return data['id'].toString();
    return '';
  }

  /// GET review/questions -> the questions a BA can tick (active ones only).
  Future<List<ReviewQuestion>> fetchReviewQuestions({
    required String token,
  }) async {
    final data = await _send(() => _client.get(
          Uri.parse(ApiConfig.reviewQuestions),
          headers: _headers(token: token, json: false),
        ));
    final list = data is Map ? data['questions'] : null;
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map) ReviewQuestion.fromJson(Map<String, dynamic>.from(e)),
    ].where((q) => q.id > 0 && q.text.isNotEmpty).toList();
  }

  /* ------------------------------ dashboard ------------------------------ */

  /// GET dashboard/sales?period=7d|2w|1m|1y  ->  chart data for the logged-in BA.
  Future<DashboardStats> fetchDashboardSales({
    required String token,
    required String period,
  }) async {
    final data = await _send(() => _client.get(
          Uri.parse('${ApiConfig.dashboardSales}?period=$period'),
          headers: _headers(token: token, json: false),
        ));
    if (data is! Map) throw const ApiException('Unexpected server response.');
    return DashboardStats.fromJson(Map<String, dynamic>.from(data));
  }

  /* ------------------------------- leaves ------------------------------- */

  Future<List<Map<String, dynamic>>> fetchLeaves({required String token, String filter = 'all'}) async {
    final data = await _send(() => _client.get(
      Uri.parse('${ApiConfig.leaveList}?filter=$filter'),
      headers: _headers(token: token, json: false),
    ));
    final list = data is Map ? data['leaves'] : null;
    if (list is! List) return const [];
    return [for (final e in list) if (e is Map) Map<String, dynamic>.from(e)];
  }

  Future<Map<String, dynamic>> fetchLeaveThread({required String token, required int id}) async {
    final data = await _send(() => _client.get(Uri.parse(ApiConfig.leaveThread(id)), headers: _headers(token: token, json: false)));
    if (data is! Map) throw const ApiException('Unexpected server response.');
    return Map<String, dynamic>.from(data);
  }

  /// Returns the new leave id (or null if the server did not send one).
  Future<int?> applyLeave({required String token, required String fromDate, required String toDate, required String reason}) async {
    final data = await _send(() => _client.post(Uri.parse(ApiConfig.leaveApply), headers: _headers(token: token), body: jsonEncode({'from_date': fromDate, 'to_date': toDate, 'reason': reason})));
    return data is Map ? int.tryParse('${data['leave_id']}') : null;
  }

  Future<void> sendLeaveMessage({required String token, required int id, required String message}) async {
    await _send(() => _client.post(Uri.parse(ApiConfig.leaveMessage(id)), headers: _headers(token: token), body: jsonEncode({'message': message})));
  }

  Future<void> cancelLeave({required String token, required int id}) async {
    await _send(() => _client.post(Uri.parse(ApiConfig.leaveCancel(id)), headers: _headers(token: token), body: '{}'));
  }

  /* ----------------------------- complaints ----------------------------- */

  /// GET complaint/list  ->  the BA's inbox (newest activity first).
  Future<List<Complaint>> fetchComplaints({required String token}) async {
    final data = await _send(() => _client.get(
          Uri.parse(ApiConfig.complaintList),
          headers: _headers(token: token, json: false),
        ));
    final list = data is Map ? data['complaints'] : null;
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map) Complaint.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// GET complaint/thread/:id  ->  header + all messages. Marks it as read.
  Future<ComplaintThread> fetchComplaintThread({
    required String token,
    required int id,
  }) async {
    final data = await _send(() => _client.get(
          Uri.parse(ApiConfig.complaintThread(id)),
          headers: _headers(token: token, json: false),
        ));
    if (data is! Map) throw const ApiException('Unexpected server response.');
    return ComplaintThread.fromJson(Map<String, dynamic>.from(data));
  }

  /// POST complaint/create  ->  new complaint id.
  Future<int> createComplaint({
    required String token,
    required String title,
    required String description,
    Uint8List? image,
  }) async {
    final data = await _send(
      () => _client.post(
        Uri.parse(ApiConfig.complaintCreate),
        headers: _headers(token: token),
        body: jsonEncode({
          'title': title,
          'description': description,
          if (image != null) 'image_base64': base64Encode(image),
          if (image != null) 'image_mime': 'image/jpeg',
        }),
      ),
      timeout: ApiConfig.uploadTimeout,
    );
    final id = data is Map ? data['complaint_id'] : null;
    return id is num ? id.toInt() : int.tryParse('$id') ?? 0;
  }

  /// POST complaint/reply/:id  ->  complaint status after the reply
  /// (a BA reply on a resolved complaint reopens it).
  Future<String> replyToComplaint({
    required String token,
    required int id,
    String message = '',
    Uint8List? image,
  }) async {
    final data = await _send(
      () => _client.post(
        Uri.parse(ApiConfig.complaintReply(id)),
        headers: _headers(token: token),
        body: jsonEncode({
          'message': message,
          if (image != null) 'image_base64': base64Encode(image),
          if (image != null) 'image_mime': 'image/jpeg',
        }),
      ),
      timeout: ApiConfig.uploadTimeout,
    );
    return data is Map ? '${data['status'] ?? ''}'.toUpperCase() : '';
  }

  /// POST complaint/status/:id  with OPEN or RESOLVED.
  Future<String> setComplaintStatus({
    required String token,
    required int id,
    required String status,
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.complaintStatus(id)),
          headers: _headers(token: token),
          body: jsonEncode({'status': status}),
        ));
    return data is Map ? '${data['status'] ?? status}'.toUpperCase() : status;
  }

  /// GET complaint/image/:messageId  ->  picture bytes (needs the token, so
  /// Image.network cannot be used directly).
  Future<Uint8List> fetchComplaintImage({
    required String token,
    required int messageId,
  }) async {
    http.Response res;
    try {
      res = await _client
          .get(
            Uri.parse(ApiConfig.complaintImage(messageId)),
            headers: _headers(token: token, json: false),
          )
          .timeout(ApiConfig.uploadTimeout);
    } on SocketException {
      throw const ApiException('No internet connection. Please try again.');
    } on TimeoutException {
      throw const ApiException('Server took too long to respond. Try again.');
    } on http.ClientException {
      throw const ApiException('Could not reach the server. Try again.');
    }
    final type = res.headers['content-type'] ?? '';
    if (res.statusCode != 200 || !type.startsWith('image/')) {
      throw ApiException('Could not load the picture.', res.statusCode);
    }
    return res.bodyBytes;
  }
}// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';

// import 'package:http/http.dart' as http;
// import 'package:ords_ba/Api_config/api_config.dart';
// import 'package:ords_ba/Model/models.dart';

// /// Thrown for any failed API call. [message] is safe to show to the user.
// class ApiException implements Exception {
//   final String message;
//   final int? statusCode;
//   const ApiException(this.message, [this.statusCode]);

//   bool get isUnauthorized => statusCode == 401 || statusCode == 403;

//   @override
//   String toString() => message;
// }

// class LoginResult {
//   final String token;
//   final AppUser user;
//   const LoginResult(this.token, this.user);
// }

// /// Every network call of the BA module lives here.
// class Repository {
//   Repository({http.Client? client}) : _client = client ?? http.Client();
//   final http.Client _client;

//   /* ----------------------------- helpers ----------------------------- */

//   Map<String, String> _headers({String? token, bool json = true}) => {
//         'Accept': 'application/json',
//         if (json) 'Content-Type': 'application/json',
//         if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
//       };

//   dynamic _tryDecode(String body) {
//     if (body.trim().isEmpty) return null;
//     try {
//       return jsonDecode(body);
//     } catch (_) {
//       return null;
//     }
//   }

//   String? _messageOf(dynamic data) {
//     if (data is Map) {
//       for (final k in ['message', 'error', 'msg', 'detail', 'error_message']) {
//         final v = data[k];
//         if (v != null && v.toString().trim().isNotEmpty) return v.toString();
//       }
//       // ORDS error shape: {"code": "...", "message": "..."} handled above.
//       final nested = data['data'];
//       if (nested is Map) return _messageOf(nested);
//     }
//     if (data is String && data.trim().isNotEmpty) return data;
//     return null;
//   }

//   /// Sends a request, decodes the JSON and converts every kind of failure
//   /// (HTTP error, `success:false`, no internet, timeout) into [ApiException].
//   Future<dynamic> _send(Future<http.Response> Function() call) async {
//     http.Response res;
//     try {
//       res = await call().timeout(ApiConfig.timeout);
//     } on SocketException {
//       throw const ApiException('No internet connection. Please try again.');
//     } on TimeoutException {
//       throw const ApiException('Server took too long to respond. Try again.');
//     } on http.ClientException {
//       throw const ApiException('Could not reach the server. Try again.');
//     }

//     final data = _tryDecode(utf8.decode(res.bodyBytes));

//     if (res.statusCode < 200 || res.statusCode >= 300) {
//       final fallback = switch (res.statusCode) {
//         401 => 'Session expired. Please login again.',
//         403 => 'You are not allowed to do this.',
//         404 => 'Service not found (404).',
//         _ => 'Request failed (${res.statusCode}).',
//       };
//       throw ApiException(_messageOf(data) ?? fallback, res.statusCode);
//     }

//     // Some ORDS handlers answer 200 with a failure flag in the body.
//     if (data is Map) {
//       final success = data['success'];
//       final status = data['status']?.toString().toLowerCase();
//       final failed = success == false ||
//           success?.toString().toLowerCase() == 'false' ||
//           status == 'error' ||
//           status == 'fail' ||
//           status == 'failed';
//       if (failed) {
//         throw ApiException(
//             _messageOf(data) ?? 'Request failed.', res.statusCode);
//       }
//     }
//     return data;
//   }

//   /// Unwraps common response wrappers (`data`, `user`, `profile`, `result`),
//   /// descending until the innermost user-like map is reached.
//   Map<String, dynamic>? _findMap(dynamic data, [int depth = 0]) {
//     if (data is! Map) return null;
//     if (depth < 3) {
//       for (final k in ['user', 'profile', 'data', 'result']) {
//         final v = data[k];
//         if (v is Map) return _findMap(v, depth + 1);
//       }
//     }
//     return Map<String, dynamic>.from(data);
//   }

//   String? _findToken(dynamic data) {
//     if (data is Map) {
//       for (final k in [
//         'token',
//         'access_token',
//         'auth_token',
//         'session_token',
//         'bearer_token',
//       ]) {
//         final v = data[k];
//         if (v != null && v.toString().trim().isNotEmpty) return v.toString();
//       }
//       for (final k in ['data', 'result', 'user']) {
//         final t = _findToken(data[k]);
//         if (t != null) return t;
//       }
//     }
//     return null;
//   }

//   /// Reads an ORDS collection (`items` + `next.$ref` paging) fully.
//   Future<List<Map<String, dynamic>>> _getAll(String firstUrl,
//       {String? token}) async {
//     final out = <Map<String, dynamic>>[];
//     final seenUrls = <String>{};
//     String? url = firstUrl;
//     var guard = 0;

//     while (url != null && seenUrls.add(url) && guard++ < 100) {
//       final data = await _send(
//           () => _client.get(Uri.parse(url!), headers: _headers(token: token, json: false)));

//       List? items;
//       if (data is List) {
//         items = data;
//       } else if (data is Map) {
//         items = (data['items'] ?? data['data'] ?? data['results']) as List?;
//       }
//       for (final e in items ?? const []) {
//         if (e is Map) out.add(Map<String, dynamic>.from(e));
//       }

//       String? next;
//       if (data is Map) {
//         final n = data['next'];
//         if (n is Map && n[r'$ref'] != null) next = n[r'$ref'].toString();
//         if (data['hasMore'] == false) next = null;
//       }
//       if ((items ?? const []).isEmpty) next = null;
//       url = next;
//     }
//     return out;
//   }

//   /* ------------------------------ locations ------------------------------ */

  

// Future<List<MartLocation>> fetchLocations() async {
//   final response = await http.get(
//     Uri.parse('http://tapex.mezangrp.com/ords/hrms/ba-sales-v2/locations/list/'),
//     headers: {
//       'Accept': 'application/json',
//     },
//   );

//   if (response.statusCode != 200) {
//     throw ApiException(
//       'Failed to load locations. HTTP ${response.statusCode}',
//     );
//   }

// final Map<String, dynamic> data = jsonDecode(response.body);

// if (data['success'] != true) {
//   throw Exception(
//     data['message']?.toString() ?? 'Failed to fetch locations',
//   );
// }

// final List<dynamic> items = data['locations'] as List<dynamic>? ?? [];

// return items.map((item) {
//   return MartLocation.fromJson(
//     Map<String, dynamic>.from(item as Map),
//   );
// }).toList();
// }

//   /* -------------------------------- auth -------------------------------- */

//   Future<String> signup({
//     required String fullName,
//     required String email,
//     required String cnic,
//     required String password,
//     required String confirmPassword,
//     required int locationId,
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.signup),
//           headers: _headers(),
//           body: jsonEncode({
//             'full_name': fullName,
//             'email': email,
//             'cnic': cnic,
//             'password': password,
//             'confirm_password': confirmPassword,
//             'role': 'BA',
//             'location_id': locationId,
//           }),
//         ));
//     return _messageOf(data) ?? 'Account created. Please login.';
//   }

//   Future<LoginResult> login({
//     required String email,
//     required String password,
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.login),
//           headers: _headers(),
//           body: jsonEncode({'email': email, 'password': password}),
//         ));

//     final token = _findToken(data);
//     if (token == null) {
//       throw const ApiException('Login succeeded but no token was returned.');
//     }
//     final map = _findMap(data) ?? {};
//     final user = AppUser.fromJson(map);
//     return LoginResult(
//       token,
//       user.email.isEmpty ? user.mergeWith(AppUser(id: '', fullName: 'BA', email: email)) : user,
//     );
//   }

//   Future<AppUser> fetchProfile(String token) async {
//     final data = await _send(() => _client.get(
//           Uri.parse(ApiConfig.profile),
//           headers: _headers(token: token, json: false),
//         ));
//     final map = _findMap(data);
//     if (map == null) throw const ApiException('Could not read profile.');
//     return AppUser.fromJson(map);
//   }

//   /* ----------------------------- attendance ----------------------------- */

//   Future<String> attendanceIn({
//     required String token,
//     required double latitude,
//     required double longitude,
//        required int locationId,
//   }) =>
//       _attendance(ApiConfig.attendanceIn, token, latitude, longitude,locationId,
//           'Attendance IN marked.');

//   Future<String> attendanceOut({
//     required String token,
//     required double latitude,
//     required double longitude,
//        required int locationId,
//   }) =>
//       _attendance(ApiConfig.attendanceOut, token, latitude, longitude,locationId,
//           'Attendance OUT marked.');

//   Future<String> _attendance(String url, String token, double lat, double lng,int locationId,
//       String fallback) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(url),
//           headers: _headers(token: token),
//           body: jsonEncode({'latitude': lat, 'longitude': lng}),
//         ));
//     return _messageOf(data) ?? fallback;
//   }

//   /* -------------------------------- sales -------------------------------- */

//   /// Active SKUs only (inactive ones are skipped).
//   Future<List<Sku>> fetchSkus() async {
//     final rows = await _getAll(ApiConfig.skuList);
//     final seen = <int>{};
//     final out = <Sku>[];
//     for (final r in rows) {
//       if (!Sku.isActive(r)) continue;
//       final s = Sku.fromJson(r);
//       if (s.skuId == 0 || !seen.add(s.skuId)) continue;
//       out.add(s);
//     }
//     out.sort((a, b) {
//       final g = a.group.toLowerCase().compareTo(b.group.toLowerCase());
//       return g != 0 ? g : a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
//     });
//     return out;
//   }

//   Future<String> enterSales({
//     required String token,
//     required int locationId,
//     required String saleDate, // yyyy-MM-dd
//     required Map<int, int> quantities, // sku_id -> qty
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.enterSales),
//           headers: _headers(token: token),
//           body: jsonEncode({
//             'location_id': locationId,
//             'sale_date': saleDate,
//             'items': [
//               for (final e in quantities.entries)
//                 {'sku_id': e.key, 'quantity': e.value},
//             ],
//           }),
//         ));
//     return _messageOf(data) ?? 'Sales saved.';
//   }
// }
