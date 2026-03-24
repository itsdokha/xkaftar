import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';


class PushNotificationsService {
  PushNotificationsService();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  final StreamController<String> _tokenController = StreamController<String>.broadcast();
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _messageOpenedSubscription;
  bool _initialized = false;
  bool _firebaseReady = false;
  bool _disposed = false;
  String? _currentToken;

  Stream<String> get tokenStream => _tokenController.stream;
  String? get currentToken => _currentToken;
  bool get messagingAvailable => _firebaseReady;
  bool get supportsDesktopLocalNotifications =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  String get platformLabel {
    if (kIsWeb) {
      return 'web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  Future<void> initialize({
    required String? Function() selectedChatIdResolver,
    required Future<void> Function(String chatId) onChatTap,
  }) async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    await _initializeLocalNotifications(onChatTap);
    if (!_supportsFirebaseMessaging()) {
      return;
    }
    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('Firebase init skipped: $error');
      return;
    }
    _firebaseReady = true;
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    final token = await messaging.getToken();
    if (token != null && token.isNotEmpty) {
      _currentToken = token;
      if (!_disposed && !_tokenController.isClosed) {
        _tokenController.add(token);
      }
    }
    _tokenRefreshSubscription = messaging.onTokenRefresh.listen((token) {
      _currentToken = token;
      if (!_disposed && !_tokenController.isClosed) {
        _tokenController.add(token);
      }
    });
    _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen((message) async {
      final chatId = _chatIdFromData(message.data);
      if (chatId != null && chatId == selectedChatIdResolver()) {
        return;
      }
      await _showForegroundNotification(message);
    });
    _messageOpenedSubscription = FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      final chatId = _chatIdFromData(message.data);
      if (chatId != null) {
        await onChatTap(chatId);
      }
    });
    final initialMessage = await messaging.getInitialMessage();
    final initialChatId = initialMessage == null ? null : _chatIdFromData(initialMessage.data);
    if (initialChatId != null) {
      await onChatTap(initialChatId);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_tokenRefreshSubscription?.cancel());
    unawaited(_foregroundMessageSubscription?.cancel());
    unawaited(_messageOpenedSubscription?.cancel());
    unawaited(_tokenController.close());
  }

  Future<void> _initializeLocalNotifications(
    Future<void> Function(String chatId) onChatTap,
  ) async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
    );
    const windowsSettings = WindowsInitializationSettings(
      appName: 'Kaftar',
      appUserModelId: 'Kuchizu.Kaftar.Client.1',
      guid: '6b6fdb5e-7808-4b66-b5e5-9f7d0db5f3d2',
    );
    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );
    await _localNotifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) async {
        final chatId = response.payload;
        if (chatId != null && chatId.isNotEmpty) {
          await onChatTap(chatId);
        }
      },
    );
    final androidImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();
    await androidImplementation?.createNotificationChannel(
      const AndroidNotificationChannel(
        'messages',
        'Messages',
        description: 'Kaftar message notifications',
        importance: Importance.high,
      ),
    );
    final darwinImplementation = _localNotifications
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await darwinImplementation?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  Future<void> showChatMessageNotification({
    required String chatId,
    required String title,
    required String body,
  }) async {
    await _showNotification(
      chatId: chatId,
      title: title,
      body: body,
    );
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final chatId = _chatIdFromData(message.data);
    final title = message.notification?.title ?? message.data['title'] ?? 'Kaftar';
    final body = message.notification?.body ?? message.data['body'] ?? 'New message';
    await _showNotification(
      chatId: chatId,
      title: title,
      body: body,
    );
  }

  Future<void> _showNotification({
    required String? chatId,
    required String title,
    required String body,
  }) async {
    await _localNotifications.show(
      title.hashCode ^ body.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Kaftar message notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
        linux: LinuxNotificationDetails(
          defaultActionName: 'Open notification',
          urgency: LinuxNotificationUrgency.normal,
        ),
        windows: WindowsNotificationDetails(),
      ),
      payload: chatId,
    );
  }

  String? _chatIdFromData(Map<String, dynamic> data) {
    final value = data['chat_id'];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  bool _supportsFirebaseMessaging() {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}
