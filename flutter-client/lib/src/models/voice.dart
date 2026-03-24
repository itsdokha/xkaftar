import 'package:livekit_client/livekit_client.dart' as lk;

import 'user.dart';

class VoiceParticipantModel {
  const VoiceParticipantModel({
    required this.user,
    required this.joinedAt,
    required this.isMuted,
    this.connectionQuality = 'unknown',
    this.hasCamera = false,
    this.isScreenSharing = false,
    this.pingMs,
    this.packetLossPercent,
  });

  factory VoiceParticipantModel.fromJson(Map<String, dynamic> json) {
    return VoiceParticipantModel(
      user: UserModel.fromJson(json['user'] as Map<String, dynamic>),
      joinedAt: DateTime.tryParse(json['joined_at'] as String? ?? '') ?? DateTime.now(),
      isMuted: json['is_muted'] == true,
      connectionQuality: json['connection_quality'] as String? ?? 'unknown',
      hasCamera: json['has_camera'] == true,
      isScreenSharing: json['is_screen_sharing'] == true,
      pingMs: json['ping_ms'] as int?,
      packetLossPercent: (json['packet_loss_percent'] as num?)?.toDouble(),
    );
  }

  final UserModel user;
  final DateTime joinedAt;
  final bool isMuted;
  final String connectionQuality;
  final bool hasCamera;
  final bool isScreenSharing;
  final int? pingMs;
  final double? packetLossPercent;

  VoiceParticipantModel copyWith({
    UserModel? user,
    DateTime? joinedAt,
    bool? isMuted,
    String? connectionQuality,
    bool? hasCamera,
    bool? isScreenSharing,
    Object? pingMs = _copySentinel,
    Object? packetLossPercent = _copySentinel,
  }) {
    return VoiceParticipantModel(
      user: user ?? this.user,
      joinedAt: joinedAt ?? this.joinedAt,
      isMuted: isMuted ?? this.isMuted,
      connectionQuality: connectionQuality ?? this.connectionQuality,
      hasCamera: hasCamera ?? this.hasCamera,
      isScreenSharing: isScreenSharing ?? this.isScreenSharing,
      pingMs: identical(pingMs, _copySentinel) ? this.pingMs : pingMs as int?,
      packetLossPercent: identical(packetLossPercent, _copySentinel)
          ? this.packetLossPercent
          : packetLossPercent as double?,
    );
  }
}

const Object _copySentinel = Object();

class VoiceVideoTileModel {
  const VoiceVideoTileModel({
    required this.user,
    required this.track,
    required this.isLocal,
    required this.isScreenShare,
  });

  final UserModel user;
  final lk.VideoTrack track;
  final bool isLocal;
  final bool isScreenShare;
}

class VoiceAudioSettingsModel {
  const VoiceAudioSettingsModel({
    required this.echoCancellation,
    required this.noiseSuppression,
    required this.autoGainControl,
    required this.masterVolume,
  });

  const VoiceAudioSettingsModel.defaults()
      : echoCancellation = true,
        noiseSuppression = true,
        autoGainControl = true,
        masterVolume = 1.0;

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;
  final double masterVolume;

  VoiceAudioSettingsModel copyWith({
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? autoGainControl,
    double? masterVolume,
  }) {
    return VoiceAudioSettingsModel(
      echoCancellation: echoCancellation ?? this.echoCancellation,
      noiseSuppression: noiseSuppression ?? this.noiseSuppression,
      autoGainControl: autoGainControl ?? this.autoGainControl,
      masterVolume: masterVolume ?? this.masterVolume,
    );
  }
}

class VoiceStateModel {
  const VoiceStateModel({
    required this.chatId,
    required this.roomName,
    required this.roomActive,
    required this.participants,
    required this.updatedAt,
  });

  factory VoiceStateModel.fromJson(Map<String, dynamic> json) {
    return VoiceStateModel(
      chatId: json['chat_id'] as String,
      roomName: json['room_name'] as String? ?? '',
      roomActive: json['room_active'] == true,
      participants: (json['participants'] as List<dynamic>? ?? const [])
          .map((item) => VoiceParticipantModel.fromJson(item as Map<String, dynamic>))
          .toList(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
    );
  }

  final String chatId;
  final String roomName;
  final bool roomActive;
  final List<VoiceParticipantModel> participants;
  final DateTime updatedAt;

  VoiceStateModel copyWith({
    String? chatId,
    String? roomName,
    bool? roomActive,
    List<VoiceParticipantModel>? participants,
    DateTime? updatedAt,
  }) {
    return VoiceStateModel(
      chatId: chatId ?? this.chatId,
      roomName: roomName ?? this.roomName,
      roomActive: roomActive ?? this.roomActive,
      participants: participants ?? this.participants,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class VoiceJoinModel {
  const VoiceJoinModel({
    required this.chatId,
    required this.roomName,
    required this.serverUrl,
    required this.participantToken,
    required this.participantIdentity,
    required this.state,
  });

  factory VoiceJoinModel.fromJson(Map<String, dynamic> json) {
    return VoiceJoinModel(
      chatId: json['chat_id'] as String,
      roomName: json['room_name'] as String? ?? '',
      serverUrl: json['server_url'] as String,
      participantToken: json['participant_token'] as String,
      participantIdentity: json['participant_identity'] as String,
      state: VoiceStateModel.fromJson(json['state'] as Map<String, dynamic>),
    );
  }

  final String chatId;
  final String roomName;
  final String serverUrl;
  final String participantToken;
  final String participantIdentity;
  final VoiceStateModel state;
}

class VoiceRoomSnapshot {
  const VoiceRoomSnapshot({
    required this.status,
    required this.participants,
    required this.speakingUserIds,
    required this.isMuted,
    required this.isCameraEnabled,
    required this.isScreenShareEnabled,
    required this.videoTiles,
    this.pingMs,
    this.packetLossPercent,
  });

  final String status;
  final List<VoiceParticipantModel> participants;
  final Set<String> speakingUserIds;
  final bool isMuted;
  final bool isCameraEnabled;
  final bool isScreenShareEnabled;
  final List<VoiceVideoTileModel> videoTiles;
  final int? pingMs;
  final double? packetLossPercent;
}
