import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_config.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/user.dart';
import '../models/voice.dart';
import '../services/api_client.dart';
import '../services/mobile_voice_background.dart';
import '../services/push_notifications.dart';
import '../services/realtime_client.dart';
import '../services/token_store.dart';
import '../services/voice_room_client.dart';

class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController({
    required this.config,
    required this.tokenStore,
  }) : api = ApiClient(baseUrl: config.apiBaseUrl) {
    api.onSessionInvalid = _handleRemoteSessionInvalid;
  }

  final AppConfig config;
  final TokenStore tokenStore;
  final ApiClient api;
  final RealtimeClient _realtime = RealtimeClient();
  final VoiceRoomClient _voiceRoom = VoiceRoomClient();
  final MobileVoiceBackground _mobileVoiceBackground = const MobileVoiceBackground();
  final PushNotificationsService _pushNotifications = PushNotificationsService();
  static const _voiceEchoCancellationKey = 'kaftar_voice_echo_cancellation';
  static const _voiceNoiseSuppressionKey = 'kaftar_voice_noise_suppression';
  static const _voiceAutoGainControlKey = 'kaftar_voice_auto_gain_control';
  static const _voiceMasterVolumeKey = 'kaftar_voice_master_volume';
  static const _voiceParticipantVolumesKey = 'kaftar_voice_participant_volumes';

  bool bootstrapInProgress = true;
  bool authInProgress = false;
  bool chatsLoading = false;
  bool composerSending = false;
  String connectionStatus = 'disconnected';
  String? selectedChatId;
  String? errorMessage;
  UserModel? currentUser;
  List<ChatModel> chats = const [];
  final Map<String, List<MessageModel>> messagesByChat = {};
  final Map<String, String?> nextMessageCursorByChat = {};
  final Map<String, bool> hasMoreMessagesByChat = {};
  final Set<String> loadingChatIds = {};
  final Map<String, Set<String>> typingUsersByChat = {};
  final Map<String, VoiceStateModel> voiceStatesByChat = {};
  Timer? _typingStopTimer;
  bool _localTypingActive = false;
  String voiceConnectionStatus = 'disconnected';
  bool voiceMuted = false;
  String? activeVoiceChatId;
  Set<String> speakingVoiceUserIds = const <String>{};
  bool voiceCameraEnabled = false;
  bool voiceScreenShareEnabled = false;
  List<VoiceVideoTileModel> voiceVideoTiles = const <VoiceVideoTileModel>[];
  int? voicePingMs;
  double? voicePacketLossPercent;
  VoiceAudioSettingsModel voiceAudioSettings = const VoiceAudioSettingsModel.defaults();
  Map<String, double> voiceParticipantVolumes = const <String, double>{};
  bool _lifecycleObserverRegistered = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  bool _voiceJoinInProgress = false;
  bool _voiceBackgroundTransitionInProgress = false;
  StreamSubscription<String>? _pushTokenSubscription;
  String? _registeredPushToken;
  String? _pendingNotificationChatId;
  Timer? _realtimeReconnectTimer;
  bool _realtimeShouldReconnect = false;
  int _realtimeReconnectAttempt = 0;
  bool _voicePresencePrimed = false;
  String? _activeComposerSendChatId;
  final Set<String> _pendingReadChatIds = <String>{};
  bool _realtimeAuthRefreshInProgress = false;
  String? latestNoticeMessage;
  int _latestNoticeId = 0;
  final Set<String> _locallyHandledChatRemovals = <String>{};
  bool _handlingRemoteSessionInvalid = false;
  final Map<String, _OutgoingMessageTask> _outgoingMessageTasks = <String, _OutgoingMessageTask>{};

  bool get isAuthenticated => currentUser != null;

  int get noticeId => _latestNoticeId;

  ChatModel? get selectedChat {
    final chatId = selectedChatId;
    if (chatId == null) {
      return null;
    }
    for (final chat in chats) {
      if (chat.id == chatId) {
        return chat;
      }
    }
    return null;
  }

  List<MessageModel> get selectedMessages {
    final chatId = selectedChatId;
    if (chatId == null) {
      return const [];
    }
    return messagesByChat[chatId] ?? const [];
  }

  bool hasMoreMessages(String chatId) => hasMoreMessagesByChat[chatId] ?? false;

  bool isLoadingMessages(String chatId) => loadingChatIds.contains(chatId);

  Future<void> initialize() async {
    if (!_lifecycleObserverRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
    }
    bootstrapInProgress = true;
    notifyListeners();
    try {
      await _pushNotifications.initialize(
        selectedChatIdResolver: () => selectedChatId,
        onChatTap: _handleNotificationChatTap,
      );
      _pushTokenSubscription ??= _pushNotifications.tokenStream.listen((_) {
        unawaited(_syncPushToken());
      });
      await _loadVoiceAudioSettings();
      final storedTokens = await tokenStore.read();
      if (storedTokens != null) {
        final session = await api.restoreSession(storedTokens);
        await _applyAuthenticatedSession(session);
      }
    } on ApiException catch (error) {
      await logout(notify: false, unregisterPush: false);
      errorMessage = error.message;
    } catch (_) {
      await logout(notify: false, unregisterPush: false);
    } finally {
      bootstrapInProgress = false;
      notifyListeners();
    }
  }

  Future<void> login({
    required String email,
    required String password,
  }) async {
    authInProgress = true;
    errorMessage = null;
    notifyListeners();
    try {
      final session = await api.login(email: email, password: password);
      await _applyAuthenticatedSession(session);
    } on ApiException catch (error) {
      errorMessage = error.message;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
    } finally {
      authInProgress = false;
      notifyListeners();
    }
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    authInProgress = true;
    errorMessage = null;
    notifyListeners();
    try {
      final session = await api.register(
        email: email,
        password: password,
        displayName: displayName,
      );
      await _applyAuthenticatedSession(session);
    } on ApiException catch (error) {
      errorMessage = error.message;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
    } finally {
      authInProgress = false;
      notifyListeners();
    }
  }

  Future<void> logout({bool notify = true, bool unregisterPush = true}) async {
    if (unregisterPush) {
      await _unregisterPushToken();
    } else {
      _registeredPushToken = null;
    }
    _stopTyping();
    _realtimeShouldReconnect = false;
    _cancelRealtimeReconnect();
    _realtime.disconnect();
    api.clearTokens();
    await tokenStore.clear();
    currentUser = null;
    chats = const [];
    selectedChatId = null;
    messagesByChat.clear();
    nextMessageCursorByChat.clear();
    hasMoreMessagesByChat.clear();
    typingUsersByChat.clear();
    voiceStatesByChat.clear();
    connectionStatus = 'disconnected';
    voiceConnectionStatus = 'disconnected';
    voiceMuted = false;
    voiceCameraEnabled = false;
    voiceScreenShareEnabled = false;
    voiceVideoTiles = const <VoiceVideoTileModel>[];
    voicePingMs = null;
    voicePacketLossPercent = null;
    activeVoiceChatId = null;
    speakingVoiceUserIds = const <String>{};
    errorMessage = null;
    await _voiceRoom.disconnect();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> loadChats() async {
    if (!isAuthenticated) {
      return;
    }
    chatsLoading = true;
    notifyListeners();
    try {
      final loadedChats = await api.listChats();
      chats = _sortChats(loadedChats);
      if (selectedChatId != null && chats.every((chat) => chat.id != selectedChatId)) {
        selectedChatId = null;
      }
      errorMessage = null;
    } on ApiException catch (error) {
      errorMessage = error.message;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
    } finally {
      chatsLoading = false;
      notifyListeners();
    }
  }

  Future<void> createDirectChat(String email) async {
    errorMessage = null;
    notifyListeners();
    try {
      final chat = await api.createDirectChat(email);
      _upsertChat(chat);
      await selectChat(chat.id);
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
    }
  }

  Future<void> createGroupChat({
    required String title,
    required List<String> memberEmails,
  }) async {
    errorMessage = null;
    notifyListeners();
    try {
      final chat = await api.createGroupChat(
        title: title,
        memberEmails: memberEmails,
      );
      _upsertChat(chat);
      await selectChat(chat.id);
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
    }
  }

  Future<void> refreshChats() async {
    await loadChats();
    final chatId = selectedChatId;
    if (chatId != null) {
      await loadMessages(chatId);
    }
  }

  Future<ServerHealthResult> checkServerHealth() async {
    return api.checkServerHealth();
  }

  Future<List<UserModel>> listUsers() async {
    return api.listUsers();
  }

  Future<bool> revokeAllSessionsForUser(UserModel user) async {
    errorMessage = null;
    notifyListeners();
    try {
      await api.revokeAllSessionsForUser(user.id);
      _pushNotice('Revoked all sessions for ${user.displayName}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateMyProfile({
    required String displayName,
    required String bio,
  }) async {
    errorMessage = null;
    notifyListeners();
    try {
      final user = await api.updateMyProfile(
        displayName: displayName,
        bio: bio,
      );
      _replaceUser(user);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  VoiceStateModel? voiceStateForChat(String chatId) => voiceStatesByChat[chatId];

  List<VoiceParticipantModel> voiceParticipantsForChat(String chatId) {
    final state = voiceStatesByChat[chatId];
    if (state == null) {
      return const [];
    }
    return state.participants;
  }

  String voiceSummaryForChat(ChatModel chat) {
    final state = voiceStateForChat(chat.id);
    final count = state?.participants.length ?? 0;
    final idleLabel = chat.type == 'group' ? 'Voice room is empty' : 'Call is idle';
    final singularLabel = chat.type == 'group' ? '1 person in voice' : '1 person in call';
    final pluralSuffix = chat.type == 'group' ? 'people in voice' : 'people in call';
    if (count <= 0) {
      return idleLabel;
    }
    if (count == 1) {
      return singularLabel;
    }
    return '$count $pluralSuffix';
  }

  Future<void> loadVoiceState(String chatId) async {
    try {
      final state = await api.getVoiceState(chatId);
      _upsertVoiceState(state);
      notifyListeners();
    } on ApiException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 409) {
        voiceStatesByChat.remove(chatId);
        notifyListeners();
        return;
      }
      errorMessage = error.message;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> selectChat(String chatId) async {
    if (selectedChatId == chatId && messagesByChat.containsKey(chatId)) {
      return;
    }
    _stopTyping();
    selectedChatId = chatId;
    _markChatUnreadCount(chatId, 0);
    notifyListeners();
    await loadMessages(chatId);
    await loadVoiceState(chatId);
  }

  void clearSelectedChat() {
    _stopTyping();
    selectedChatId = null;
    notifyListeners();
  }

  Future<void> loadMessages(String chatId, {bool loadMore = false}) async {
    if (loadingChatIds.contains(chatId)) {
      return;
    }
    loadingChatIds.add(chatId);
    notifyListeners();
    try {
      final page = await api.listMessages(
        chatId,
        beforeMessageId: loadMore ? nextMessageCursorByChat[chatId] : null,
      );
      final current = messagesByChat[chatId] ?? const <MessageModel>[];
      final items = loadMore
          ? [...page.items.where((message) => current.every((entry) => entry.id != message.id)), ...current]
          : page.items;
      messagesByChat[chatId] = _sortMessages(items);
      nextMessageCursorByChat[chatId] = page.nextBeforeMessageId;
      hasMoreMessagesByChat[chatId] = page.hasMore;
      _markChatUnreadCount(chatId, 0);
      errorMessage = null;
    } on ApiException catch (error) {
      errorMessage = error.message;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
    } finally {
      loadingChatIds.remove(chatId);
      notifyListeners();
    }
  }

  Future<bool> sendMessage(String body, {String? replyToMessageId}) async {
    final chatId = selectedChatId;
    if (chatId == null || body.trim().isEmpty || composerSending) {
      return false;
    }
    final pendingMessage = _createPendingMessage(
      chatId: chatId,
      body: body.trim(),
      kind: 'user',
      imageUrl: null,
      videoUrl: null,
      replyToMessageId: replyToMessageId,
    );
    _insertPendingMessage(pendingMessage);
    _stopTyping();
    unawaited(
      _sendOutgoingMessage(
        pendingMessage.id,
        () => api.sendMessage(
          chatId,
          body: body.trim(),
          replyToMessageId: replyToMessageId,
          clientMessageId: pendingMessage.id,
        ),
      ),
    );
    return true;
  }

  Future<bool> sendImageMessage({
    required List<int> bytes,
    required String filename,
    String body = '',
    String? replyToMessageId,
  }) async {
    final chatId = selectedChatId;
    if (chatId == null || composerSending) {
      return false;
    }
    final pendingMessage = _createPendingMessage(
      chatId: chatId,
      body: body.trim().isEmpty ? 'Photo' : body.trim(),
      kind: 'user',
      imageUrl: null,
      videoUrl: null,
      replyToMessageId: replyToMessageId,
    );
    _insertPendingMessage(pendingMessage);
    _stopTyping();
    unawaited(
      _sendOutgoingMessage(
        pendingMessage.id,
        () => api.sendImageMessage(
          chatId,
          bytes: bytes,
          filename: filename,
          body: body.trim(),
          replyToMessageId: replyToMessageId,
          clientMessageId: pendingMessage.id,
        ),
      ),
    );
    return true;
  }

  Future<bool> sendTriangleVideoMessage({
    required List<int> bytes,
    required String filename,
    String body = '',
    String? replyToMessageId,
  }) async {
    final chatId = selectedChatId;
    if (chatId == null || composerSending) {
      return false;
    }
    final pendingMessage = _createPendingMessage(
      chatId: chatId,
      body: body.trim().isEmpty ? 'Triangle video' : body.trim(),
      kind: 'triangle_video',
      imageUrl: null,
      videoUrl: null,
      replyToMessageId: replyToMessageId,
    );
    _insertPendingMessage(pendingMessage);
    _stopTyping();
    unawaited(
      _sendOutgoingMessage(
        pendingMessage.id,
        () => api.sendTriangleVideoMessage(
          chatId,
          bytes: bytes,
          filename: filename,
          body: body.trim(),
          replyToMessageId: replyToMessageId,
          clientMessageId: pendingMessage.id,
        ),
      ),
    );
    return true;
  }

  void toggleReaction(String chatId, String messageId, String emoji) {
    final messages = messagesByChat[chatId];
    if (messages == null || currentUser == null) return;
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    final message = messages[index];
    final user = currentUser!;
    final hasReaction = message.reactions.any(
      (r) => r.emoji == emoji && r.user.id == user.id,
    );
    final now = DateTime.now();

    final updatedReactions = hasReaction
        ? message.reactions.where((r) => !(r.emoji == emoji && r.user.id == user.id)).toList()
        : [
            ...message.reactions.where((r) => r.user.id != user.id),
            MessageReactionModel(emoji: emoji, user: user, createdAt: now),
          ];
    final mutable = [...messages];
    mutable[index] = message.copyWith(reactions: updatedReactions);
    messagesByChat[chatId] = mutable;
    notifyListeners();

    final future = hasReaction
        ? api.removeReaction(chatId, messageId, emoji)
        : api.addReaction(chatId, messageId, emoji);
    unawaited(
      future.then<void>((updated) {
        _applyUpdatedMessage(updated);
      }).catchError((Object _) {}),
    );
  }

  void retryFailedMessage(String messageId) {
    final message = _messageById(messageId);
    if (message == null || message.localState != MessageLocalState.failed || !canRetryMessage(message)) {
      return;
    }
    errorMessage = null;
    _updateLocalMessageState(messageId, MessageLocalState.sending, retryCount: 0);
    final chatId = message.chatId;
    unawaited(
      _sendOutgoingMessage(
        messageId,
        () => api.sendMessage(
          chatId,
          body: message.body,
          replyToMessageId: message.replyTo?.id,
          clientMessageId: messageId,
        ),
      ),
    );
  }

  Future<bool> addMemberToSelectedChat(String email) async {
    final chatId = selectedChatId;
    if (chatId == null || email.trim().isEmpty) {
      return false;
    }
    errorMessage = null;
    notifyListeners();
    try {
      final chat = await api.addMember(chatId, email.trim());
      _upsertChat(chat);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateSelectedGroupIcon({
    required List<int> bytes,
    required String filename,
  }) async {
    final chatId = selectedChatId;
    if (chatId == null) {
      return false;
    }
    errorMessage = null;
    notifyListeners();
    try {
      final chat = await api.updateGroupIcon(
        chatId,
        bytes: bytes,
        filename: filename,
      );
      _upsertChat(chat);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> uploadAvatar({
    required List<int> bytes,
    required String filename,
  }) async {
    errorMessage = null;
    notifyListeners();
    try {
      final user = await api.uploadAvatar(bytes: bytes, filename: filename);
      _replaceUser(user);
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> joinSelectedVoiceRoom() async {
    final chat = selectedChat;
    if (chat == null) {
      return false;
    }
    return _joinVoiceRoom(chat.id);
  }

  Future<void> setVoiceEchoCancellation(bool value) async {
    voiceAudioSettings = voiceAudioSettings.copyWith(echoCancellation: value);
    await _persistVoiceAudioSettings();
    notifyListeners();
    await _reconnectVoiceIfNeeded();
  }

  Future<void> setVoiceNoiseSuppression(bool value) async {
    voiceAudioSettings = voiceAudioSettings.copyWith(noiseSuppression: value);
    await _persistVoiceAudioSettings();
    notifyListeners();
    await _reconnectVoiceIfNeeded();
  }

  Future<void> setVoiceAutoGainControl(bool value) async {
    voiceAudioSettings = voiceAudioSettings.copyWith(autoGainControl: value);
    await _persistVoiceAudioSettings();
    notifyListeners();
    await _reconnectVoiceIfNeeded();
  }

  double voiceParticipantVolumeForUser(String userId) {
    return voiceParticipantVolumes[userId] ?? 1.0;
  }

  Future<void> setVoiceMasterVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    voiceAudioSettings = voiceAudioSettings.copyWith(masterVolume: normalized);
    await _persistVoiceAudioSettings();
    await _voiceRoom.setMasterVolume(normalized);
    notifyListeners();
  }

  Future<void> setVoiceParticipantVolume(String userId, double value) async {
    final normalized = value.clamp(0.0, 1.0).toDouble();
    voiceParticipantVolumes = {
      ...voiceParticipantVolumes,
      userId: normalized,
    };
    await _persistVoiceAudioSettings();
    await _voiceRoom.setParticipantVolume(userId, normalized);
    notifyListeners();
  }

  Future<void> toggleVoiceCamera() async {
    try {
      await _voiceRoom.toggleCamera();
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
    }
  }

  Future<void> setVoiceScreenShareEnabled(bool enabled, {String? desktopSourceId}) async {
    try {
      if (enabled && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final backgroundEnabled = await _mobileVoiceBackground.enable();
        if (!backgroundEnabled) {
          errorMessage = 'Background permission is required for Android screen sharing.';
          notifyListeners();
          return;
        }
      }
      await _voiceRoom.setScreenShareEnabled(enabled, desktopSourceId: desktopSourceId);
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
    }
  }

  String voiceConnectionLabel() {
    switch (voiceConnectionStatus) {
      case 'connected':
        return 'Connected';
      case 'connecting':
        return 'Connecting';
      case 'reconnecting':
        return 'Reconnecting';
      case 'error':
        return 'Connection issue';
      default:
        return 'Disconnected';
    }
  }

  Future<bool> _joinVoiceRoom(String chatId) async {
    if (_voiceJoinInProgress) {
      return false;
    }
    _voiceJoinInProgress = true;
    errorMessage = null;
    voiceConnectionStatus = 'connecting';
    activeVoiceChatId = chatId;
    _voicePresencePrimed = false;
    notifyListeners();
    try {
      final join = await api.joinVoiceRoom(chatId);
      _upsertVoiceState(join.state);
      await _voiceRoom.connect(
        join: join,
        audioSettings: voiceAudioSettings,
        onSnapshot: (snapshot) {
          voiceConnectionStatus = snapshot.status;
          if (snapshot.status == 'error' || snapshot.status == 'disconnected') {
            voiceMuted = false;
            voiceCameraEnabled = false;
            voiceScreenShareEnabled = false;
            voiceVideoTiles = const <VoiceVideoTileModel>[];
            voicePingMs = null;
            voicePacketLossPercent = null;
            activeVoiceChatId = null;
            speakingVoiceUserIds = const <String>{};
            _voicePresencePrimed = false;
            unawaited(_mobileVoiceBackground.disable());
            notifyListeners();
            return;
          }
          voiceMuted = snapshot.isMuted;
          voiceCameraEnabled = snapshot.isCameraEnabled;
          voiceScreenShareEnabled = snapshot.isScreenShareEnabled;
          voiceVideoTiles = snapshot.videoTiles;
          voicePingMs = snapshot.pingMs;
          voicePacketLossPercent = snapshot.packetLossPercent;
          activeVoiceChatId = chatId;
          speakingVoiceUserIds = snapshot.speakingUserIds;
          final mergedParticipants = _mergeVoiceParticipants(chatId, snapshot.participants);
          _handleVoicePresenceChange(chatId, mergedParticipants);
          _upsertVoiceState(VoiceStateModel(
            chatId: chatId,
            roomName: join.roomName,
            roomActive: snapshot.participants.isNotEmpty,
            participants: mergedParticipants,
            updatedAt: DateTime.now(),
          ));
          notifyListeners();
        },
        onError: (error) {
          _handleVoiceConnectError(chatId, error);
        },
      );
      await _voiceRoom.setMasterVolume(voiceAudioSettings.masterVolume);
      for (final entry in voiceParticipantVolumes.entries) {
        await _voiceRoom.setParticipantVolume(entry.key, entry.value);
      }
      if (voiceConnectionStatus == 'error' || activeVoiceChatId != chatId) {
        return false;
      }
      if (_appLifecycleState == AppLifecycleState.resumed) {
        await _mobileVoiceBackground.disable();
      }
      return true;
    } on ApiException catch (error) {
      _handleVoiceConnectError(chatId, error.message);
      return false;
    } catch (error) {
      _handleVoiceConnectError(chatId, 'Unexpected error: $error');
      return false;
    } finally {
      _voiceJoinInProgress = false;
    }
  }

  Future<void> leaveVoiceRoom() async {
    final chatId = activeVoiceChatId;
    await _voiceRoom.disconnect();
    await _mobileVoiceBackground.disable();
    voiceConnectionStatus = 'disconnected';
    voiceMuted = false;
    voiceCameraEnabled = false;
    voiceScreenShareEnabled = false;
    voiceVideoTiles = const <VoiceVideoTileModel>[];
    voicePingMs = null;
    voicePacketLossPercent = null;
    speakingVoiceUserIds = const <String>{};
    activeVoiceChatId = null;
    _voicePresencePrimed = false;
    if (chatId != null) {
      await loadVoiceState(chatId);
    } else {
      notifyListeners();
    }
  }

  Future<void> toggleVoiceMute() async {
    try {
      await _voiceRoom.toggleMute();
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
    }
  }

  Future<void> _reconnectVoiceIfNeeded() async {
    final chatId = activeVoiceChatId;
    if (chatId == null || voiceConnectionStatus == 'disconnected' || _voiceJoinInProgress) {
      return;
    }
    voiceConnectionStatus = 'reconnecting';
    notifyListeners();
    await _voiceRoom.disconnect();
    await _joinVoiceRoom(chatId);
  }

  void clearError() {
    if (errorMessage == null) {
      return;
    }
    errorMessage = null;
    notifyListeners();
  }

  void handleComposerChanged(String text) {
    final chatId = selectedChatId;
    if (chatId == null || connectionStatus != 'connected') {
      return;
    }
    if (text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_localTypingActive) {
      _localTypingActive = true;
      _realtime.send({
        'type': 'typing',
        'chat_id': chatId,
        'is_typing': true,
      });
    }
    _typingStopTimer?.cancel();
    _typingStopTimer = Timer(
      const Duration(milliseconds: 1400),
      _stopTyping,
    );
  }

  String chatTitle(ChatModel chat) {
    if (chat.type == 'group') {
      return chat.title?.trim().isNotEmpty == true ? chat.title! : 'Untitled group';
    }
    final currentUserId = currentUser?.id;
    for (final member in chat.members) {
      if (member.user.id != currentUserId) {
        return member.user.displayName;
      }
    }
    return 'Direct chat';
  }

  UserModel? directCounterpart(ChatModel chat) {
    if (chat.type == 'group') {
      return null;
    }
    final currentUserId = currentUser?.id;
    for (final member in chat.members) {
      if (member.user.id != currentUserId) {
        return member.user;
      }
    }
    return null;
  }

  Future<bool> setChatNotificationsEnabled(String chatId, bool enabled) async {
    errorMessage = null;
    final existing = _firstOrNull(chats.where((item) => item.id == chatId));
    if (existing == null) {
      return false;
    }
    _upsertChat(existing.copyWith(notificationsEnabled: enabled));
    try {
      final updatedChat = await api.updateChatNotifications(chatId, enabled);
      _upsertChat(updatedChat);
      return true;
    } on ApiException catch (error) {
      _upsertChat(existing);
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      _upsertChat(existing);
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> renameSelectedGroup(String title) async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      errorMessage = 'Group title cannot be empty';
      notifyListeners();
      return false;
    }
    if (trimmedTitle == (chat.title ?? '').trim()) {
      return true;
    }
    try {
      final updated = await api.renameGroupChat(chat.id, trimmedTitle);
      _upsertChat(updated);
      _pushNotice('Group renamed to "$trimmedTitle"');
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> leaveSelectedGroup() async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    try {
      await api.leaveGroupChat(chat.id);
      _locallyHandledChatRemovals.add(chat.id);
      _removeChatLocally(chat.id, notify: false);
      _pushNotice('You left ${chatTitle(chat)}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteSelectedGroup() async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    try {
      await api.deleteGroupChat(chat.id);
      _locallyHandledChatRemovals.add(chat.id);
      _removeChatLocally(chat.id, notify: false);
      _pushNotice('${chatTitle(chat)} was deleted');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeMemberFromSelectedGroup(String userId, String displayName) async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    try {
      await api.removeGroupMember(chat.id, userId);
      _pushNotice('$displayName was removed from ${chatTitle(chat)}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> muteVoiceParticipant(String userId, String displayName) async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    try {
      final state = await api.muteVoiceParticipant(chat.id, userId);
      _upsertVoiceState(state);
      _pushNotice('$displayName was muted in ${chatTitle(chat)}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  Future<bool> kickVoiceParticipant(String userId, String displayName) async {
    final chat = selectedChat;
    if (chat == null || chat.type != 'group') {
      return false;
    }
    errorMessage = null;
    try {
      final state = await api.kickVoiceParticipant(chat.id, userId);
      _upsertVoiceState(state);
      _pushNotice('$displayName was removed from voice in ${chatTitle(chat)}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      errorMessage = error.message;
      notifyListeners();
      return false;
    } catch (error) {
      errorMessage = 'Unexpected error: $error';
      notifyListeners();
      return false;
    }
  }

  UserModel? userById(String userId) {
    if (currentUser?.id == userId) {
      return currentUser;
    }
    for (final chat in chats) {
      for (final member in chat.members) {
        if (member.user.id == userId) {
          return member.user;
        }
      }
      final sender = chat.lastMessage?.sender;
      if (sender != null && sender.id == userId) {
        return sender;
      }
    }
    for (final messages in messagesByChat.values) {
      for (final message in messages) {
        if (message.sender.id == userId) {
          return message.sender;
        }
        final replySender = message.replyTo?.sender;
        if (replySender != null && replySender.id == userId) {
          return replySender;
        }
      }
    }
    return null;
  }

  String chatSubtitle(ChatModel chat) {
    final typingText = typingTextForChat(chat);
    if (typingText != null) {
      return typingText;
    }
    if (chat.type == 'group') {
      final online = chat.members.where((member) => member.user.isOnline).length;
      return '${chat.members.length} members, $online online';
    }
    final counterpart = directCounterpart(chat);
    if (counterpart == null) {
      return 'Offline';
    }
    if (counterpart.isOnline) {
      return 'Online';
    }
    if (counterpart.lastSeenAt == null) {
      return 'Offline';
    }
    return 'Last seen ${formatLastSeen(counterpart.lastSeenAt!)}';
  }

  String chatPreview(ChatModel chat) {
    final lastMessage = chat.lastMessage;
    if (lastMessage == null) {
      return 'No messages yet';
    }
    if (lastMessage.isSystem) {
      return '${lastMessage.sender.displayName} ${lastMessage.body}'.trim();
    }
    final prefix = currentUser != null && lastMessage.sender.id == currentUser!.id
        ? 'You'
        : lastMessage.sender.displayName;
    if (lastMessage.isTriangleVideo && lastMessage.body.isNotEmpty && lastMessage.body != 'Triangle video') {
      return '$prefix: Triangle video - ${lastMessage.body}';
    }
    if (lastMessage.isTriangleVideo) {
      return '$prefix: Triangle video';
    }
    if ((lastMessage.imageUrl ?? '').isNotEmpty && lastMessage.body.isNotEmpty) {
      return '$prefix: Photo - ${lastMessage.body}';
    }
    if ((lastMessage.imageUrl ?? '').isNotEmpty) {
      return '$prefix: Photo';
    }
    return '$prefix: ${lastMessage.body}';
  }

  String formatLastSeen(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final difference = DateTime(now.year, now.month, now.day).difference(
      DateTime(local.year, local.month, local.day),
    );
    final time = formatClock(local);
    if (difference.inDays == 0) {
      return 'today at $time';
    }
    if (difference.inDays == 1) {
      return 'yesterday at $time';
    }
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} $time';
  }

  String formatClock(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String formatDetailedDateTime(DateTime value) {
    final local = value.toLocal();
    final date = '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
    return '$date ${formatClock(local)}';
  }

  String formatChatListTime(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(local.year, local.month, local.day);
    final difference = today.difference(messageDate);
    if (difference.inDays == 0) {
      return formatClock(local);
    }
    if (difference.inDays == 1) {
      return 'Yesterday';
    }
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[local.month - 1]} ${local.day}';
  }

  String deliveryStatus(MessageModel message) {
    final chat = _firstOrNull(chats.where((item) => item.id == message.chatId));
    final current = currentUser;
    if (chat == null || current == null || message.sender.id != current.id) {
      return '';
    }
    switch (message.localState) {
      case MessageLocalState.sending:
        return 'sending';
      case MessageLocalState.retrying:
        return 'retrying';
      case MessageLocalState.failed:
        return 'failed';
      case MessageLocalState.none:
        break;
    }
    final otherMembers = chat.members.where((member) => member.user.id != current.id).toList();
    if (otherMembers.isEmpty) {
      return 'sent';
    }
    final read = otherMembers.every(
      (member) => member.lastReadAt != null && !member.lastReadAt!.isBefore(message.createdAt),
    );
    return read ? 'read' : 'sent';
  }

  String connectionLabel() {
    switch (connectionStatus) {
      case 'connected':
        return 'Connected';
      case 'connecting':
        return 'Connecting';
      case 'error':
        return 'Connection issue';
      default:
        return 'Disconnected';
    }
  }

  List<UserModel> typingUsersForChat(String chatId) {
    final typingIds = typingUsersByChat[chatId] ?? const <String>{};
    final chat = _firstOrNull(chats.where((item) => item.id == chatId));
    if (chat == null || typingIds.isEmpty) {
      return const [];
    }
    return chat.members
        .where((member) => typingIds.contains(member.user.id))
        .map((member) => member.user)
        .toList();
  }

  String? typingTextForChat(ChatModel chat) {
    final users = typingUsersForChat(chat.id);
    if (users.isEmpty) {
      return null;
    }
    if (users.length == 1) {
      return '${users.first.displayName} is typing...';
    }
    return '${users.length} people are typing...';
  }

  Future<void> _applyAuthenticatedSession(SessionModel session) async {
    currentUser = _normalizeUserUrls(session.user);
    errorMessage = null;
    await tokenStore.save(
      StoredTokens(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
      ),
    );
    _realtimeShouldReconnect = true;
    _cancelRealtimeReconnect();
    _connectRealtime();
    await loadChats();
    await _syncPushToken();
    await _openPendingNotificationChatIfAny();
  }

  void _connectRealtime() {
    if (!_realtimeShouldReconnect || !isAuthenticated || connectionStatus == 'connecting') {
      return;
    }
    _realtime.connect(
      url: api.websocketUrl(),
      onEvent: _handleRealtimeEvent,
      onStatus: (status) {
        connectionStatus = status;
        if (status == 'connected') {
          _realtimeReconnectAttempt = 0;
          _cancelRealtimeReconnect();
          errorMessage = null;
        } else if (status == 'disconnected' || status == 'error') {
          _scheduleRealtimeReconnect();
        }
        notifyListeners();
      },
      onError: (error) {
        errorMessage ??= error;
        _scheduleRealtimeReconnect();
        notifyListeners();
      },
      onUnauthorized: () {
        unawaited(_refreshRealtimeAuthAndReconnect());
      },
    );
  }

  Future<void> _refreshRealtimeAuthAndReconnect() async {
    if (_realtimeAuthRefreshInProgress || !isAuthenticated) {
      return;
    }
    _realtimeAuthRefreshInProgress = true;
    try {
      await api.refreshTokens();
      final accessToken = api.accessToken;
      final refreshToken = api.refreshToken;
      if (accessToken != null && refreshToken != null) {
        await tokenStore.save(
          StoredTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
          ),
        );
      }
      if (_realtimeShouldReconnect && isAuthenticated) {
        _cancelRealtimeReconnect();
        _connectRealtime();
      }
    } on SessionInvalidException catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } on ApiException catch (error) {
      errorMessage ??= error.message;
      _scheduleRealtimeReconnect();
      notifyListeners();
    } catch (error) {
      errorMessage ??= 'Unexpected error: $error';
      _scheduleRealtimeReconnect();
      notifyListeners();
    } finally {
      _realtimeAuthRefreshInProgress = false;
    }
  }

  void _cancelRealtimeReconnect() {
    _realtimeReconnectTimer?.cancel();
    _realtimeReconnectTimer = null;
  }

  void _scheduleRealtimeReconnect() {
    if (!_realtimeShouldReconnect || !isAuthenticated || connectionStatus == 'connecting') {
      return;
    }
    if (_realtimeReconnectTimer != null) {
      return;
    }
    final delaySeconds = (_realtimeReconnectAttempt + 1).clamp(1, 5) * 2;
    _realtimeReconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _realtimeReconnectTimer = null;
      if (!_realtimeShouldReconnect || !isAuthenticated) {
        return;
      }
      _realtimeReconnectAttempt = (_realtimeReconnectAttempt + 1).clamp(0, 30);
      _connectRealtime();
    });
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final eventName = event['event'];
    final data = event['data'];
    if (eventName is! String || data is! Map<String, dynamic>) {
      return;
    }
    if (eventName == 'message_created') {
      final message = MessageModel.fromJson(_normalizeMediaUrls(data));
      final foreign = currentUser != null && message.sender.id != currentUser!.id;
      if (!foreign) {
        final pendingLocalMessage = _findPendingMatch(message);
        if (pendingLocalMessage != null) {
          _replacePendingMessage(
            localId: pendingLocalMessage.id,
            deliveredMessage: message,
          );
          return;
        }
        if (composerSending &&
            _activeComposerSendChatId == message.chatId) {
          composerSending = false;
          _activeComposerSendChatId = null;
          errorMessage = null;
        }
      }
      _mergeMessage(message, foreign: foreign);
      if (foreign &&
          selectedChatId == message.chatId &&
          _appLifecycleState == AppLifecycleState.resumed) {
        _markChatUnreadCount(message.chatId, 0);
        unawaited(_markChatRead(message.chatId));
      }
      if (foreign) {
        unawaited(_showDesktopMessageNotification(message));
      }
      return;
    }
    if (eventName == 'message_updated') {
      final updated = MessageModel.fromJson(_normalizeMediaUrls(data));
      _applyUpdatedMessage(updated);
      return;
    }
    if (eventName == 'chat_updated' || eventName == 'member_added') {
      _upsertChat(ChatModel.fromJson(_normalizeMediaUrls(data)));
      return;
    }
    if (eventName == 'chat_removed') {
      final chatId = data['chat_id'];
      if (chatId is String && chatId.isNotEmpty) {
        if (_locallyHandledChatRemovals.remove(chatId)) {
          return;
        }
        final reason = data['reason'] as String? ?? 'removed';
        final title = data['title'] as String? ?? 'Chat';
        _removeChatLocally(chatId, notify: false);
        if (reason == 'deleted') {
          _pushNotice('$title was deleted');
        } else if (reason == 'left') {
          _pushNotice('You left $title');
        } else if (reason == 'removed') {
          _pushNotice('You were removed from $title');
        }
        notifyListeners();
      }
      return;
    }
    if (eventName == 'session_revoked') {
      final message = data['message'] as String? ??
          'Your session was revoked by an administrator. Please sign in again.';
      unawaited(_handleRemoteSessionInvalid(message));
      return;
    }
    if (eventName == 'presence_updated') {
      _replaceUser(UserModel.fromJson(_normalizeMediaUrls(data)));
      return;
    }
    if (eventName == 'read_state_updated') {
      notifyListeners();
      return;
    }
    if (eventName == 'voice_state_updated') {
      final state = VoiceStateModel.fromJson(_normalizeMediaUrls(data));
      _upsertVoiceState(state);
      notifyListeners();
      return;
    }
    if (eventName == 'voice_moderation_notice') {
      final action = data['action'] as String? ?? '';
      final actorDisplayName = data['actor_display_name'] as String? ?? 'A moderator';
      if (action == 'muted') {
        _pushNotice('$actorDisplayName muted you in voice');
      } else if (action == 'kicked') {
        _pushNotice('$actorDisplayName removed you from voice');
      }
      notifyListeners();
      return;
    }
    if (eventName == 'typing_updated') {
      final chatId = data['chat_id'];
      final userId = data['user_id'];
      final isTyping = data['is_typing'] == true;
      if (chatId is String && userId is String && currentUser?.id != userId) {
        final updated = {...(typingUsersByChat[chatId] ?? <String>{})};
        if (isTyping) {
          updated.add(userId);
        } else {
          updated.remove(userId);
        }
        if (updated.isEmpty) {
          typingUsersByChat.remove(chatId);
        } else {
          typingUsersByChat[chatId] = updated;
        }
        notifyListeners();
      }
    }
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
      return '${api.baseUrl}$value';
    }
    final valueUri = Uri.tryParse(value);
    final baseUri = Uri.tryParse(api.baseUrl);
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

  void _replaceUser(UserModel updatedUser) {
    updatedUser = _normalizeUserUrls(updatedUser);
    chats = chats
        .map(
          (chat) => chat.copyWith(
            members: chat.members
                .map(
                  (member) => member.user.id == updatedUser.id
                      ? member.copyWith(user: updatedUser)
                      : member,
                )
                .toList(),
            lastMessage: _replaceMessageUser(chat.lastMessage, updatedUser),
          ),
        )
        .toList();
    final nextMessages = <String, List<MessageModel>>{};
    messagesByChat.forEach((chatId, messages) {
      nextMessages[chatId] = messages
          .map((message) => _replaceMessageUser(message, updatedUser) ?? message)
          .toList();
    });
    messagesByChat
      ..clear()
      ..addAll(nextMessages);
    final nextVoiceStates = <String, VoiceStateModel>{};
    voiceStatesByChat.forEach((chatId, state) {
      nextVoiceStates[chatId] = state.copyWith(
        participants: state.participants
            .map(
              (participant) => participant.user.id == updatedUser.id
                  ? participant.copyWith(user: updatedUser)
                  : participant,
            )
            .toList(),
      );
    });
    voiceStatesByChat
      ..clear()
      ..addAll(nextVoiceStates);
    if (currentUser?.id == updatedUser.id) {
      currentUser = _normalizeUserUrls(updatedUser);
    }
    notifyListeners();
  }

  MessageModel? _replaceMessageUser(MessageModel? message, UserModel updatedUser) {
    if (message == null) {
      return null;
    }
    final nextReply = message.replyTo?.sender.id == updatedUser.id
        ? message.replyTo!.copyWith(sender: updatedUser)
        : message.replyTo;
    if (message.sender.id == updatedUser.id || nextReply != message.replyTo) {
      return message.copyWith(
        sender: message.sender.id == updatedUser.id ? updatedUser : message.sender,
        replyTo: nextReply,
      );
    }
    return message;
  }

  void _upsertChat(ChatModel chat) {
    final index = chats.indexWhere((item) => item.id == chat.id);
    if (index >= 0) {
      final mutable = [...chats];
      mutable[index] = chat;
      chats = _sortChats(mutable);
    } else {
      chats = _sortChats([...chats, chat]);
    }
    notifyListeners();
  }

  void _removeChatLocally(String chatId, {bool notify = true}) {
    final wasSelected = selectedChatId == chatId;
    if (wasSelected) {
      _stopTyping();
      selectedChatId = null;
    }
    chats = chats.where((chat) => chat.id != chatId).toList();
    messagesByChat.remove(chatId);
    nextMessageCursorByChat.remove(chatId);
    hasMoreMessagesByChat.remove(chatId);
    loadingChatIds.remove(chatId);
    typingUsersByChat.remove(chatId);
    voiceStatesByChat.remove(chatId);
    if (activeVoiceChatId == chatId) {
      activeVoiceChatId = null;
      voiceConnectionStatus = 'disconnected';
      voiceMuted = false;
      voiceCameraEnabled = false;
      voiceScreenShareEnabled = false;
      voiceVideoTiles = const <VoiceVideoTileModel>[];
      voicePingMs = null;
      voicePacketLossPercent = null;
      speakingVoiceUserIds = const <String>{};
      _voicePresencePrimed = false;
      unawaited(_voiceRoom.disconnect());
      unawaited(_mobileVoiceBackground.disable());
    }
    if (notify) {
      notifyListeners();
    }
  }

  void clearNotice() {
    latestNoticeMessage = null;
  }

  void _pushNotice(String message) {
    latestNoticeMessage = message;
    _latestNoticeId += 1;
  }

  void _mergeMessage(MessageModel message, {required bool foreign}) {
    final existing = messagesByChat[message.chatId] ?? const <MessageModel>[];
    if (existing.every((entry) => entry.id != message.id)) {
      messagesByChat[message.chatId] = _sortMessages([...existing, message]);
    }
    final chatIndex = chats.indexWhere((chat) => chat.id == message.chatId);
    if (chatIndex >= 0) {
      final chat = chats[chatIndex];
      final unreadCount = foreign && selectedChatId != message.chatId ? chat.unreadCount + 1 : chat.unreadCount;
      final updatedChat = chat.copyWith(
        lastMessage: message,
        updatedAt: message.createdAt,
        unreadCount: unreadCount,
      );
      final mutable = [...chats];
      mutable[chatIndex] = updatedChat;
      chats = _sortChats(mutable);
    }
    if (foreign) {
      final updated = {...(typingUsersByChat[message.chatId] ?? <String>{})}..remove(message.sender.id);
      if (updated.isEmpty) {
        typingUsersByChat.remove(message.chatId);
      } else {
        typingUsersByChat[message.chatId] = updated;
      }
    }
    notifyListeners();
  }

  void _applyUpdatedMessage(MessageModel updated) {
    final chatMessages = messagesByChat[updated.chatId];
    if (chatMessages != null) {
      final index = chatMessages.indexWhere((m) => m.id == updated.id);
      if (index >= 0) {
        final mutable = [...chatMessages];
        mutable[index] = updated.copyWith(
          localState: mutable[index].localState,
          localRetryCount: mutable[index].localRetryCount,
        );
        messagesByChat[updated.chatId] = mutable;
      }
    }
    final chatIndex = chats.indexWhere((chat) => chat.id == updated.chatId);
    if (chatIndex >= 0 && chats[chatIndex].lastMessage?.id == updated.id) {
      final mutableChats = [...chats];
      mutableChats[chatIndex] = mutableChats[chatIndex].copyWith(lastMessage: updated);
      chats = mutableChats;
    }
    notifyListeners();
  }

  MessageModel _createPendingMessage({
    required String chatId,
    required String body,
    required String kind,
    required String? imageUrl,
    required String? videoUrl,
    required String? replyToMessageId,
  }) {
    final current = currentUser!;
    final now = DateTime.now();
    final replySource = replyToMessageId == null
        ? null
        : _firstOrNull(
            (messagesByChat[chatId] ?? const <MessageModel>[])
                .where((message) => message.id == replyToMessageId),
          );
    return MessageModel(
      id: 'local-${now.microsecondsSinceEpoch}-${chatId.hashCode.abs()}',
      chatId: chatId,
      sender: current,
      body: body,
      createdAt: now,
      kind: kind,
      imageUrl: imageUrl,
      videoUrl: videoUrl,
      replyTo: replySource == null
          ? null
          : MessageReplyModel(
              id: replySource.id,
              sender: replySource.sender,
              body: replySource.body,
              createdAt: replySource.createdAt,
              kind: replySource.kind,
              imageUrl: replySource.imageUrl,
              videoUrl: replySource.videoUrl,
            ),
      localState: MessageLocalState.sending,
      localRetryCount: 0,
    );
  }

  void _insertPendingMessage(MessageModel message) {
    errorMessage = null;
    _mergeMessage(message, foreign: false);
  }

  Future<void> _sendOutgoingMessage(
    String localId,
    Future<MessageModel> Function() sendRequest,
  ) async {
    final task = _outgoingMessageTasks.putIfAbsent(
      localId,
      () => _OutgoingMessageTask(localId: localId),
    );
    task.attempt += 1;
    if (task.attempt > 1) {
      _updateLocalMessageState(localId, MessageLocalState.retrying, retryCount: task.attempt - 1);
    }
    try {
      final delivered = await sendRequest();
      _replacePendingMessage(localId: localId, deliveredMessage: delivered);
    } on ApiException catch (error) {
      if (_shouldRetryOutgoing(error, task.attempt)) {
        final delaySeconds = (1 << (task.attempt - 1)).clamp(2, 10);
        task.retryTimer?.cancel();
        task.retryTimer = Timer(Duration(seconds: delaySeconds), () {
          unawaited(_sendOutgoingMessage(localId, sendRequest));
        });
        _updateLocalMessageState(localId, MessageLocalState.retrying, retryCount: task.attempt);
        if (selectedChatId == _messageById(localId)?.chatId) {
          errorMessage = 'Message delivery is unstable. Retrying...';
          notifyListeners();
        }
        return;
      }
      _finalizeOutgoingFailure(localId, error.message);
    } catch (error) {
      _finalizeOutgoingFailure(localId, 'Unexpected error: $error');
    }
  }

  bool _shouldRetryOutgoing(ApiException error, int attempt) {
    if (attempt >= 4) {
      return false;
    }
    final statusCode = error.statusCode;
    if (statusCode != null && statusCode >= 500) {
      return true;
    }
    final normalized = error.message.toLowerCase();
    return normalized.contains('timed out') ||
        normalized.contains('network error') ||
        normalized.contains('request failed') ||
        normalized.contains('socket') ||
        normalized.contains('connection');
  }

  void _finalizeOutgoingFailure(String localId, String message) {
    final task = _outgoingMessageTasks.remove(localId);
    task?.retryTimer?.cancel();
    _updateLocalMessageState(localId, MessageLocalState.failed, retryCount: task?.attempt ?? 0);
    errorMessage = message;
    notifyListeners();
  }

  void _replacePendingMessage({
    required String localId,
    required MessageModel deliveredMessage,
  }) {
    final task = _outgoingMessageTasks.remove(localId);
    task?.retryTimer?.cancel();
    final chatId = deliveredMessage.chatId;
    final existing = messagesByChat[chatId] ?? const <MessageModel>[];
    messagesByChat[chatId] = _sortMessages(
      existing
          .where((entry) => entry.id != localId && entry.id != deliveredMessage.id)
          .followedBy([deliveredMessage])
          .toList(),
    );
    final chatIndex = chats.indexWhere((chat) => chat.id == chatId);
    if (chatIndex >= 0) {
      final mutable = [...chats];
      mutable[chatIndex] = mutable[chatIndex].copyWith(
        lastMessage: deliveredMessage,
        updatedAt: deliveredMessage.createdAt,
      );
      chats = _sortChats(mutable);
    }
    errorMessage = null;
    notifyListeners();
  }

  void _updateLocalMessageState(
    String localId,
    MessageLocalState state, {
    required int retryCount,
  }) {
    messagesByChat.forEach((chatId, messages) {
      final index = messages.indexWhere((message) => message.id == localId);
      if (index < 0) {
        return;
      }
      final mutable = [...messages];
      mutable[index] = mutable[index].copyWith(
        localState: state,
        localRetryCount: retryCount,
      );
      messagesByChat[chatId] = _sortMessages(mutable);
    });
    notifyListeners();
  }

  MessageModel? _messageById(String messageId) {
    for (final messages in messagesByChat.values) {
      for (final message in messages) {
        if (message.id == messageId) {
          return message;
        }
      }
    }
    return null;
  }

  MessageModel? _findPendingMatch(MessageModel deliveredMessage) {
    final current = currentUser;
    if (current == null) {
      return null;
    }
    final messages = messagesByChat[deliveredMessage.chatId] ?? const <MessageModel>[];
    for (final message in messages) {
      if (message.sender.id != current.id || message.localState == MessageLocalState.none) {
        continue;
      }
      final sameBody = message.body.trim() == deliveredMessage.body.trim();
      final sameKind = message.kind == deliveredMessage.kind;
      final sameImagePresence = (message.imageUrl ?? '').isNotEmpty == (deliveredMessage.imageUrl ?? '').isNotEmpty;
      final sameVideoPresence = (message.videoUrl ?? '').isNotEmpty == (deliveredMessage.videoUrl ?? '').isNotEmpty;
      final closeInTime = message.createdAt.difference(deliveredMessage.createdAt).inSeconds.abs() <= 30;
      if (sameBody && sameKind && sameImagePresence && sameVideoPresence && closeInTime) {
        return message;
      }
    }
    return null;
  }

  bool canRetryMessage(MessageModel message) {
    return !message.hasImage && !message.hasVideo && !message.isTriangleVideo;
  }

  void _markChatUnreadCount(String chatId, int unreadCount) {
    final index = chats.indexWhere((chat) => chat.id == chatId);
    if (index < 0) {
      return;
    }
    final mutable = [...chats];
    mutable[index] = mutable[index].copyWith(unreadCount: unreadCount);
    chats = mutable;
  }

  Future<void> _markChatRead(String chatId) async {
    if (_pendingReadChatIds.contains(chatId)) {
      return;
    }
    _pendingReadChatIds.add(chatId);
    try {
      final chat = await api.markChatRead(chatId);
      _upsertChat(chat.copyWith(unreadCount: 0));
    } catch (_) {
    } finally {
      _pendingReadChatIds.remove(chatId);
    }
  }

  List<ChatModel> _sortChats(List<ChatModel> items) {
    final mutable = [...items];
    mutable.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return mutable;
  }

  List<MessageModel> _sortMessages(List<MessageModel> items) {
    final mutable = [...items];
    mutable.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return mutable;
  }

  void _stopTyping() {
    final chatId = selectedChatId;
    _typingStopTimer?.cancel();
    _typingStopTimer = null;
    if (!_localTypingActive || chatId == null) {
      _localTypingActive = false;
      return;
    }
    _localTypingActive = false;
    if (connectionStatus == 'connected') {
      _realtime.send({
        'type': 'typing',
        'chat_id': chatId,
        'is_typing': false,
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (activeVoiceChatId == null) {
      return;
    }
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        break;
      case AppLifecycleState.resumed:
        unawaited(_handleVoiceAppResumed());
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _typingStopTimer?.cancel();
    for (final task in _outgoingMessageTasks.values) {
      task.retryTimer?.cancel();
    }
    _outgoingMessageTasks.clear();
    _realtimeShouldReconnect = false;
    _cancelRealtimeReconnect();
    unawaited(_pushTokenSubscription?.cancel());
    _realtime.disconnect();
    _voiceRoom.disconnect();
    unawaited(_mobileVoiceBackground.disable());
    _pushNotifications.dispose();
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    api.dispose();
    super.dispose();
  }

  Future<void> _loadVoiceAudioSettings() async {
    final preferences = await SharedPreferences.getInstance();
    final rawParticipantVolumes = preferences.getString(_voiceParticipantVolumesKey);
    Map<String, double> parsedParticipantVolumes = const <String, double>{};
    if (rawParticipantVolumes != null && rawParticipantVolumes.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawParticipantVolumes);
        if (decoded is Map) {
          parsedParticipantVolumes = decoded.map(
            (key, value) => MapEntry(
              key.toString(),
              ((value as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0).toDouble(),
            ),
          );
        }
      } catch (_) {}
    }
    voiceAudioSettings = VoiceAudioSettingsModel(
      echoCancellation: preferences.getBool(_voiceEchoCancellationKey) ?? true,
      noiseSuppression: preferences.getBool(_voiceNoiseSuppressionKey) ?? true,
      autoGainControl: preferences.getBool(_voiceAutoGainControlKey) ?? true,
      masterVolume: (preferences.getDouble(_voiceMasterVolumeKey) ?? 1.0).clamp(0.0, 1.0).toDouble(),
    );
    voiceParticipantVolumes = parsedParticipantVolumes;
  }

  Future<void> _persistVoiceAudioSettings() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_voiceEchoCancellationKey, voiceAudioSettings.echoCancellation);
    await preferences.setBool(_voiceNoiseSuppressionKey, voiceAudioSettings.noiseSuppression);
    await preferences.setBool(_voiceAutoGainControlKey, voiceAudioSettings.autoGainControl);
    await preferences.setDouble(_voiceMasterVolumeKey, voiceAudioSettings.masterVolume);
    await preferences.setString(_voiceParticipantVolumesKey, jsonEncode(voiceParticipantVolumes));
  }

  void _upsertVoiceState(VoiceStateModel state) {
    voiceStatesByChat[state.chatId] = state.copyWith(
      participants: _mergeVoiceParticipants(state.chatId, state.participants),
    );
  }

  Future<void> _syncPushToken() async {
    if (!isAuthenticated || !_pushNotifications.messagingAvailable) {
      return;
    }
    final token = _pushNotifications.currentToken;
    if (token == null || token.isEmpty || token == _registeredPushToken) {
      return;
    }
    try {
      await api.registerPushToken(
        token: token,
        platform: _pushNotifications.platformLabel,
      );
      _registeredPushToken = token;
    } catch (_) {}
  }

  Future<void> _unregisterPushToken() async {
    final token = _registeredPushToken ?? _pushNotifications.currentToken;
    if (!isAuthenticated || token == null || token.isEmpty) {
      _registeredPushToken = null;
      return;
    }
    try {
      await api.unregisterPushToken(token);
    } catch (_) {}
    _registeredPushToken = null;
  }

  Future<void> _handleNotificationChatTap(String chatId) async {
    if (!isAuthenticated) {
      _pendingNotificationChatId = chatId;
      return;
    }
    if (chats.every((chat) => chat.id != chatId)) {
      await loadChats();
    }
    if (chats.any((chat) => chat.id == chatId)) {
      await selectChat(chatId);
      return;
    }
    _pendingNotificationChatId = chatId;
  }

  Future<void> _openPendingNotificationChatIfAny() async {
    final chatId = _pendingNotificationChatId;
    if (chatId == null) {
      return;
    }
    _pendingNotificationChatId = null;
    await _handleNotificationChatTap(chatId);
  }

  Future<void> _showDesktopMessageNotification(MessageModel message) async {
    if (!_pushNotifications.supportsDesktopLocalNotifications) {
      return;
    }
    final isSameChatOpen =
        _appLifecycleState == AppLifecycleState.resumed && selectedChatId == message.chatId;
    if (isSameChatOpen) {
      return;
    }
    final chat = _firstOrNull(chats.where((item) => item.id == message.chatId));
    if (chat == null) {
      return;
    }
    if (!chat.notificationsEnabled) {
      return;
    }
    final title = chat.type == 'group'
        ? '${chatTitle(chat)} • ${message.sender.displayName}'
        : message.sender.displayName;
    final body = (message.imageUrl ?? '').isNotEmpty
        ? (message.body.trim().isEmpty ? 'Photo' : 'Photo • ${message.body.trim()}')
        : (message.body.trim().isEmpty ? 'New message' : message.body.trim());
    try {
      await _pushNotifications.showChatMessageNotification(
        chatId: message.chatId,
        title: title,
        body: message.isTriangleVideo
            ? (message.body.trim().isEmpty ? 'Triangle video' : 'Triangle video • ${message.body.trim()}')
            : body,
      );
    } catch (_) {}
  }

  Future<void> _ensureVoiceBackgroundMode() async {
    if (activeVoiceChatId == null ||
        _voiceBackgroundTransitionInProgress ||
        _appLifecycleState == AppLifecycleState.resumed ||
        (voiceConnectionStatus != 'connected' && voiceConnectionStatus != 'reconnecting') ||
        _voiceRoom.chatId != activeVoiceChatId) {
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && !voiceScreenShareEnabled) {
      return;
    }
    _voiceBackgroundTransitionInProgress = true;
    try {
      final enabled = await _mobileVoiceBackground.enable();
      if (!enabled) {
        errorMessage ??= 'Background voice mode permission was not granted';
        notifyListeners();
      }
    } finally {
      _voiceBackgroundTransitionInProgress = false;
    }
  }

  Future<void> _handleVoiceAppResumed() async {
    final chatId = activeVoiceChatId;
    if (chatId == null) {
      return;
    }
    if (!_voiceBackgroundTransitionInProgress) {
      _voiceBackgroundTransitionInProgress = true;
      try {
        await _mobileVoiceBackground.disable();
      } finally {
        _voiceBackgroundTransitionInProgress = false;
      }
    }
    if (_voiceJoinInProgress) {
      return;
    }
    if (_voiceRoom.chatId != chatId ||
        voiceConnectionStatus == 'disconnected' ||
        voiceConnectionStatus == 'error') {
      await _joinVoiceRoom(chatId);
      return;
    }
    await loadVoiceState(chatId);
  }

  void _handleVoiceConnectError(String chatId, String error) {
    errorMessage = _friendlyVoiceError(error);
    voiceConnectionStatus = 'error';
    voiceMuted = false;
    voiceCameraEnabled = false;
    voiceScreenShareEnabled = false;
    voiceVideoTiles = const <VoiceVideoTileModel>[];
    voicePingMs = null;
    voicePacketLossPercent = null;
    speakingVoiceUserIds = const <String>{};
    _voicePresencePrimed = false;
    if (activeVoiceChatId == chatId) {
      activeVoiceChatId = null;
    }
    unawaited(_mobileVoiceBackground.disable());
    notifyListeners();
  }

  String _friendlyVoiceError(String error) {
    final normalized = error.trim();
    if (normalized.contains('MediaConnectException') ||
        normalized.contains('Timed out waiting for PeerConnection')) {
      return 'Voice connection timed out. Check TURN/UDP ports or firewall on the LiveKit server.';
    }
    return normalized;
  }

  List<VoiceParticipantModel> _mergeVoiceParticipants(
    String chatId,
    List<VoiceParticipantModel> incoming,
  ) {
    final previousState = voiceStatesByChat[chatId];
    final previousById = {
      for (final participant in previousState?.participants ?? const <VoiceParticipantModel>[])
        participant.user.id: participant,
    };
    final chat = _firstOrNull(chats.where((item) => item.id == chatId));
    final memberUsersById = {
      for (final member in chat?.members ?? const <ChatMemberModel>[])
        member.user.id: member.user,
    };
    return incoming.map((participant) {
      final previous = previousById[participant.user.id];
      final chatUser = memberUsersById[participant.user.id];
      final displayName = participant.user.displayName.isNotEmpty
          ? participant.user.displayName
          : previous?.user.displayName.isNotEmpty == true
              ? previous!.user.displayName
              : (chatUser?.displayName ?? participant.user.id);
      final avatarUrl = _normalizeUrlValue(
        participant.user.avatarUrl?.isNotEmpty == true
            ? participant.user.avatarUrl!
            : previous?.user.avatarUrl?.isNotEmpty == true
                ? previous!.user.avatarUrl!
                : (chatUser?.avatarUrl ?? ''),
      );
      final connectionQuality = participant.connectionQuality != 'unknown'
          ? participant.connectionQuality
          : (previous?.connectionQuality ?? 'unknown');
      return participant.copyWith(
        user: participant.user.copyWith(
          displayName: displayName,
          avatarUrl: avatarUrl.isEmpty ? null : avatarUrl,
          email: participant.user.email.isNotEmpty
              ? participant.user.email
              : (previous?.user.email.isNotEmpty == true
                  ? previous!.user.email
                  : (chatUser?.email ?? '')),
          bio: participant.user.bio?.isNotEmpty == true
              ? participant.user.bio
              : (previous?.user.bio?.isNotEmpty == true
                  ? previous!.user.bio
                  : chatUser?.bio),
        ),
        joinedAt: previous?.joinedAt ?? participant.joinedAt,
        connectionQuality: connectionQuality,
        pingMs: participant.pingMs ?? previous?.pingMs,
        packetLossPercent: participant.packetLossPercent ?? previous?.packetLossPercent,
      );
    }).toList();
  }

  void _handleVoicePresenceChange(
    String chatId,
    List<VoiceParticipantModel> nextParticipants,
  ) {
    if (activeVoiceChatId != chatId) {
      return;
    }
    final previousParticipants = voiceStatesByChat[chatId]?.participants ?? const <VoiceParticipantModel>[];
    final previousIds = {for (final participant in previousParticipants) participant.user.id};
    final nextIds = {for (final participant in nextParticipants) participant.user.id};
    if (!_voicePresencePrimed) {
      _voicePresencePrimed = true;
      return;
    }
    final joined = nextIds.difference(previousIds);
    final left = previousIds.difference(nextIds);
    if (joined.isNotEmpty) {
      unawaited(SystemSound.play(SystemSoundType.click));
    }
    if (left.isNotEmpty) {
      unawaited(SystemSound.play(SystemSoundType.alert));
    }
  }

  UserModel _normalizeUserUrls(UserModel user) {
    final avatarUrl = user.avatarUrl;
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return user;
    }
    return user.copyWith(avatarUrl: _normalizeUrlValue(avatarUrl));
  }

  T? _firstOrNull<T>(Iterable<T> values) {
    if (values.isEmpty) {
      return null;
    }
    return values.first;
  }

  Future<void> _handleRemoteSessionInvalid(String message) async {
    if (_handlingRemoteSessionInvalid) {
      return;
    }
    _handlingRemoteSessionInvalid = true;
    try {
      await logout(notify: false, unregisterPush: false);
      errorMessage = message;
      notifyListeners();
    } finally {
      _handlingRemoteSessionInvalid = false;
    }
  }
}

class _OutgoingMessageTask {
  _OutgoingMessageTask({required this.localId});

  final String localId;
  int attempt = 0;
  Timer? retryTimer;
}
