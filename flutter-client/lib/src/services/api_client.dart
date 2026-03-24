import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/user.dart';
import '../models/voice.dart';
import 'token_store.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class SessionInvalidException extends ApiException {
  const SessionInvalidException(super.message, {super.statusCode});
}

class ServerHealthResult {
  const ServerHealthResult({
    required this.status,
    required this.environment,
    required this.latencyMs,
  });

  final String status;
  final String environment;
  final int latencyMs;
}

class LinkPreviewResult {
  const LinkPreviewResult({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
}

class ApiClient {
  ApiClient({required String baseUrl})
      : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  static const Duration _requestTimeout = Duration(seconds: 20);
  static const Duration _uploadTimeout = Duration(seconds: 90);

  final String _baseUrl;
  final http.Client _httpClient = http.Client();
  String? _accessToken;
  String? _refreshToken;
  Future<void> Function(String message)? onSessionInvalid;
  bool _sessionInvalidNotified = false;

  String get baseUrl => _baseUrl;
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;

  void dispose() {
    _httpClient.close();
  }

  void setTokens({
    required String accessToken,
    required String refreshToken,
  }) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _sessionInvalidNotified = false;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
    _sessionInvalidNotified = false;
  }

  Future<SessionModel> login({
    required String email,
    required String password,
  }) async {
    final response = await _send(
      'POST',
      '/auth/login',
      authenticated: false,
      body: {
        'email': email,
        'password': password,
      },
    );
    final session = SessionModel.fromJson(_unwrapJsonObject(response));
    setTokens(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
    return session;
  }

  Future<SessionModel> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final response = await _send(
      'POST',
      '/auth/register',
      authenticated: false,
      body: {
        'email': email,
        'password': password,
        'display_name': displayName,
      },
    );
    final session = SessionModel.fromJson(_unwrapJsonObject(response));
    setTokens(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
    return session;
  }

  Future<SessionModel> restoreSession(StoredTokens tokens) async {
    setTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    final user = await getMe();
    return SessionModel(
      user: user,
      accessToken: _accessToken!,
      refreshToken: _refreshToken!,
    );
  }

  Future<UserModel> getMe() async {
    final response = await _send('GET', '/users/me');
    return UserModel.fromJson(_unwrapJsonObject(response));
  }

  Future<List<UserModel>> listUsers() async {
    final response = await _send('GET', '/users');
    return _unwrapJsonList(response).map(UserModel.fromJson).toList();
  }

  Future<void> revokeAllSessionsForUser(String userId) async {
    await _send('POST', '/admin/users/$userId/revoke-sessions');
  }

  Future<UserModel> updateMyProfile({
    required String displayName,
    required String bio,
  }) async {
    final response = await _send(
      'POST',
      '/users/me',
      body: {
        'display_name': displayName,
        'bio': bio,
      },
    );
    return UserModel.fromJson(_unwrapJsonObject(response));
  }

  Future<VoiceJoinModel> joinVoiceRoom(String chatId) async {
    final response = await _send('POST', '/chats/$chatId/voice/join');
    return VoiceJoinModel.fromJson(_unwrapJsonObject(response));
  }

  Future<VoiceStateModel> getVoiceState(String chatId) async {
    final response = await _send('GET', '/chats/$chatId/voice/state');
    return VoiceStateModel.fromJson(_unwrapJsonObject(response));
  }

  Future<VoiceStateModel> muteVoiceParticipant(String chatId, String userId) async {
    final response = await _send('POST', '/chats/$chatId/voice/participants/$userId/mute');
    return VoiceStateModel.fromJson(_unwrapJsonObject(response));
  }

  Future<VoiceStateModel> kickVoiceParticipant(String chatId, String userId) async {
    final response = await _send('DELETE', '/chats/$chatId/voice/participants/$userId');
    return VoiceStateModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ServerHealthResult> checkServerHealth() async {
    final stopwatch = Stopwatch()..start();
    final response = await _send(
      'GET',
      '/health',
      authenticated: false,
      allowRefresh: false,
    );
    stopwatch.stop();
    final data = _unwrapJsonObject(response);
    return ServerHealthResult(
      status: data['status'] as String? ?? 'unknown',
      environment: data['environment'] as String? ?? 'unknown',
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<List<ChatModel>> listChats() async {
    final response = await _send('GET', '/chats');
    return _unwrapJsonList(response).map(ChatModel.fromJson).toList();
  }

  Future<ChatModel> getChat(String chatId) async {
    final response = await _send('GET', '/chats/$chatId');
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<MessagePageModel> listMessages(
    String chatId, {
    int limit = 50,
    String? beforeMessageId,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    if (beforeMessageId != null && beforeMessageId.isNotEmpty) {
      query['before_message_id'] = beforeMessageId;
    }
    final response = await _send(
      'GET',
      '/chats/$chatId/messages',
      queryParameters: query,
    );
    return MessagePageModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> markChatRead(String chatId) async {
    final response = await _send('POST', '/chats/$chatId/read');
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<MessageModel> sendMessage(
    String chatId, {
    required String body,
    String? replyToMessageId,
    String? clientMessageId,
  }) async {
    final response = await _send(
      'POST',
      '/chats/$chatId/messages',
      body: {
        'body': body,
        if (replyToMessageId != null && replyToMessageId.isNotEmpty) 'reply_to_message_id': replyToMessageId,
        if (clientMessageId != null && clientMessageId.isNotEmpty) 'client_message_id': clientMessageId,
      },
    );
    return MessageModel.fromJson(_unwrapJsonObject(response));
  }

  Future<MessageModel> sendImageMessage(
    String chatId, {
    required List<int> bytes,
    required String filename,
    String body = '',
    String? replyToMessageId,
    String? clientMessageId,
  }) async {
    final response = await _sendMultipart(
      'POST',
      '/chats/$chatId/images',
      fileField: 'file',
      fileBytes: bytes,
      filename: filename,
      fields: {
        'body': body,
        if (replyToMessageId != null && replyToMessageId.isNotEmpty) 'reply_to_message_id': replyToMessageId,
        if (clientMessageId != null && clientMessageId.isNotEmpty) 'client_message_id': clientMessageId,
      },
    );
    return MessageModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> createDirectChat(String email) async {
    final response = await _send(
      'POST',
      '/chats/direct',
      body: {'email': email},
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> createGroupChat({
    required String title,
    required List<String> memberEmails,
  }) async {
    final response = await _send(
      'POST',
      '/chats/group',
      body: {
        'title': title,
        'member_emails': memberEmails,
      },
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> addMember(String chatId, String email) async {
    final response = await _send(
      'POST',
      '/chats/$chatId/members',
      body: {'email': email},
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> updateChatNotifications(String chatId, bool enabled) async {
    final response = await _send(
      'POST',
      '/chats/$chatId/notifications',
      body: {'enabled': enabled},
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<ChatModel> renameGroupChat(String chatId, String title) async {
    final response = await _send(
      'POST',
      '/chats/$chatId/rename',
      body: {'title': title},
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<void> leaveGroupChat(String chatId) async {
    await _send('POST', '/chats/$chatId/leave');
  }

  Future<void> deleteGroupChat(String chatId) async {
    await _send('DELETE', '/chats/$chatId');
  }

  Future<void> removeGroupMember(String chatId, String userId) async {
    await _send('DELETE', '/chats/$chatId/members/$userId');
  }

  Future<ChatModel> updateGroupIcon(
    String chatId, {
    required List<int> bytes,
    required String filename,
  }) async {
    final response = await _sendMultipart(
      'POST',
      '/chats/$chatId/icon',
      fileField: 'file',
      fileBytes: bytes,
      filename: filename,
    );
    return ChatModel.fromJson(_unwrapJsonObject(response));
  }

  Future<UserModel> uploadAvatar({
    required List<int> bytes,
    required String filename,
  }) async {
    final response = await _sendMultipart(
      'POST',
      '/users/me/avatar',
      fileField: 'file',
      fileBytes: bytes,
      filename: filename,
    );
    return UserModel.fromJson(_unwrapJsonObject(response));
  }

  Future<void> registerPushToken({
    required String token,
    required String platform,
  }) async {
    await _send(
      'POST',
      '/devices/push/register',
      body: {
        'token': token,
        'platform': platform,
      },
    );
  }

  Future<void> unregisterPushToken(String token) async {
    await _send(
      'POST',
      '/devices/push/unregister',
      body: {'token': token},
    );
  }

  Future<MessageModel> addReaction(String chatId, String messageId, String emoji) async {
    final response = await _send(
      'POST',
      '/chats/$chatId/messages/$messageId/reactions',
      queryParameters: {'emoji': emoji},
    );
    return MessageModel.fromJson(_unwrapJsonObject(response));
  }

  Future<MessageModel> removeReaction(String chatId, String messageId, String emoji) async {
    final response = await _send(
      'DELETE',
      '/chats/$chatId/messages/$messageId/reactions',
      queryParameters: {'emoji': emoji},
    );
    return MessageModel.fromJson(_unwrapJsonObject(response));
  }

  Future<LinkPreviewResult?> fetchLinkPreview(String url) async {
    try {
      final response = await _send(
        'POST',
        '/utils/link-preview',
        queryParameters: {'url': url},
      );
      final data = _unwrapJsonObject(response);
      final title = data['title'] as String?;
      final description = data['description'] as String?;
      if (title == null && description == null) return null;
      return LinkPreviewResult(
        url: data['url'] as String? ?? url,
        title: title,
        description: description,
        imageUrl: data['image_url'] as String?,
        siteName: data['site_name'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  String websocketUrl() {
    final accessToken = _accessToken;
    if (accessToken == null) {
      throw const ApiException('No access token');
    }
    final base = Uri.parse(_baseUrl);
    final path = base.path.isEmpty || base.path == '/' ? '/ws' : '${base.path}/ws';
    return base
        .replace(
          scheme: base.scheme == 'https' ? 'wss' : 'ws',
          path: path,
          queryParameters: {'token': accessToken},
        )
        .toString();
  }

  Future<void> refreshTokens() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      const message = 'Your session is no longer valid. Please sign in again.';
      await _notifySessionInvalid(message);
      throw const SessionInvalidException(message, statusCode: 401);
    }
    late final http.Response response;
    try {
      response = await _send(
        'POST',
        '/auth/refresh',
        authenticated: false,
        allowRefresh: false,
        body: {'refresh_token': refreshToken},
      );
    } on ApiException catch (error) {
      if (error.statusCode == 401) {
        final message = _friendlyUnauthorizedMessage(error.message);
        await _notifySessionInvalid(message);
        throw SessionInvalidException(message, statusCode: 401);
      }
      rethrow;
    }
    final data = _unwrapJsonObject(response);
    setTokens(
      accessToken: data['access_token'] as String,
      refreshToken: refreshToken,
    );
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, dynamic>? body,
    bool authenticated = true,
    bool allowRefresh = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: queryParameters);
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (authenticated && _accessToken != null) 'Authorization': 'Bearer $_accessToken',
    };
    final encodedBody = body == null ? null : jsonEncode(body);
    late final http.Response response;
    try {
      if (method == 'GET') {
        response = await _httpClient.get(uri, headers: headers).timeout(_requestTimeout);
      } else if (method == 'POST') {
        response = await _httpClient.post(uri, headers: headers, body: encodedBody).timeout(_requestTimeout);
      } else if (method == 'DELETE') {
        response = await _httpClient.delete(uri, headers: headers).timeout(_requestTimeout);
      } else {
        throw ApiException('Unsupported method $method');
      }
    } on TimeoutException {
      throw const ApiException('Request timed out');
    } on SocketException catch (error) {
      throw ApiException('Network error: ${error.message}');
    } on http.ClientException catch (error) {
      throw ApiException('Request failed: ${error.message}');
    }
    if (response.statusCode == 401 && authenticated && allowRefresh && _refreshToken != null) {
      await refreshTokens();
      return _send(
        method,
        path,
        queryParameters: queryParameters,
        body: body,
        authenticated: authenticated,
        allowRefresh: false,
      );
    }
    if (response.statusCode >= 400) {
      if (response.statusCode == 401 && authenticated) {
        final message = _friendlyUnauthorizedMessage(_extractErrorMessage(response));
        await _notifySessionInvalid(message);
        throw SessionInvalidException(
          message,
          statusCode: response.statusCode,
        );
      }
      throw ApiException(
        _extractErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  Future<http.Response> _sendMultipart(
    String method,
    String path, {
    required String fileField,
    required List<int> fileBytes,
    required String filename,
    Map<String, String>? fields,
    bool authenticated = true,
    bool allowRefresh = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final request = http.MultipartRequest(method, uri);
    request.headers['Accept'] = 'application/json';
    if (authenticated && _accessToken != null) {
      request.headers['Authorization'] = 'Bearer $_accessToken';
    }
    if (fields != null) {
      request.fields.addAll(fields);
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        fileField,
        fileBytes,
        filename: filename,
        contentType: _mediaTypeForFilename(filename),
      ),
    );
    late final http.Response response;
    try {
      final streamed = await request.send().timeout(_uploadTimeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiException('Upload timed out');
    } on SocketException catch (error) {
      throw ApiException('Network error: ${error.message}');
    } on http.ClientException catch (error) {
      throw ApiException('Request failed: ${error.message}');
    }
    if (response.statusCode == 401 && authenticated && allowRefresh && _refreshToken != null) {
      await refreshTokens();
      return _sendMultipart(
        method,
        path,
        fileField: fileField,
        fileBytes: fileBytes,
        filename: filename,
        fields: fields,
        authenticated: authenticated,
        allowRefresh: false,
      );
    }
    if (response.statusCode >= 400) {
      if (response.statusCode == 401 && authenticated) {
        final message = _friendlyUnauthorizedMessage(_extractErrorMessage(response));
        await _notifySessionInvalid(message);
        throw SessionInvalidException(
          message,
          statusCode: response.statusCode,
        );
      }
      throw ApiException(
        _extractErrorMessage(response),
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  MediaType _mediaTypeForFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return MediaType('image', 'jpeg');
    }
    if (lower.endsWith('.png')) {
      return MediaType('image', 'png');
    }
    if (lower.endsWith('.webp')) {
      return MediaType('image', 'webp');
    }
    if (lower.endsWith('.gif')) {
      return MediaType('image', 'gif');
    }
    return MediaType('application', 'octet-stream');
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final detail = decoded['detail'];
        if (detail is String && detail.isNotEmpty) {
          return detail;
        }
      }
    } catch (_) {}
    return response.body.isEmpty ? 'Request failed' : response.body;
  }

  Map<String, dynamic> _unwrapJsonObject(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const ApiException('Unexpected response shape');
    }
    return _normalizeMediaUrls(decoded);
  }

  List<Map<String, dynamic>> _unwrapJsonList(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const ApiException('Unexpected response shape');
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(_normalizeMediaUrls)
        .toList();
  }

  Map<String, dynamic> _normalizeMediaUrls(Map<String, dynamic> input) {
    final output = <String, dynamic>{};
    input.forEach((key, value) {
      if (value is String && key.endsWith('_url')) {
        output[key] = _normalizeUrlValue(value);
      } else if (value is Map<String, dynamic>) {
        output[key] = _normalizeMediaUrls(value);
      } else if (value is List) {
        output[key] = value
            .map((item) => item is Map<String, dynamic> ? _normalizeMediaUrls(item) : item)
            .toList();
      } else {
        output[key] = value;
      }
    });
    return output;
  }

  String _normalizeUrlValue(String value) {
    if (!(value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('ws://') ||
        value.startsWith('wss://'))) {
      return '$_baseUrl$value';
    }
    final valueUri = Uri.tryParse(value);
    final baseUri = Uri.tryParse(_baseUrl);
    if (valueUri == null || baseUri == null) {
      return value;
    }
    if (_isLoopbackHost(valueUri.host) && !_isLoopbackHost(baseUri.host)) {
      return Uri(
        scheme: baseUri.scheme,
        userInfo: valueUri.userInfo,
        host: baseUri.host,
        port: baseUri.hasPort ? baseUri.port : null,
        path: valueUri.path,
        query: valueUri.hasQuery ? valueUri.query : null,
        fragment: valueUri.hasFragment ? valueUri.fragment : null,
      ).toString();
    }
    return value;
  }

  bool _isLoopbackHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == '127.0.0.1' ||
        normalized == 'localhost' ||
        normalized == '::1';
  }

  Future<void> _notifySessionInvalid(String message) async {
    if (_sessionInvalidNotified) {
      return;
    }
    _sessionInvalidNotified = true;
    await onSessionInvalid?.call(message);
  }

  String _friendlyUnauthorizedMessage(String message) {
    final normalized = message.trim().toLowerCase();
    if (normalized.contains('revoked')) {
      return 'Your session was revoked by an administrator. Please sign in again.';
    }
    if (normalized.contains('refresh token is invalid or expired') ||
        normalized.contains('session is no longer valid') ||
        normalized.contains('session is invalid') ||
        normalized.contains('invalid token') ||
        normalized.contains('user not found')) {
      return 'Your session is no longer valid. Please sign in again.';
    }
    return message;
  }
}
