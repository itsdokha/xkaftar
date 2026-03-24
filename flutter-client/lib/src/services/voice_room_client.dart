import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../models/user.dart';
import '../models/voice.dart';

class VoiceRoomClient {
  dynamic _room;
  VoidCallback? _listener;
  String? _chatId;
  bool _isMuted = false;
  bool _isCameraEnabled = false;
  bool _isScreenShareEnabled = false;
  void Function(VoiceRoomSnapshot snapshot)? _onSnapshot;
  double _masterVolume = 1.0;
  final Map<String, double> _participantVolumes = <String, double>{};
  Timer? _statsPollTimer;
  int? _pingMs;
  double? _packetLossPercent;
  final Map<String, _VoiceDiagnostics> _participantDiagnosticsByUserId = <String, _VoiceDiagnostics>{};

  String? get chatId => _chatId;

  Future<void> setMasterVolume(double value) async {
    _masterVolume = value.clamp(0.0, 1.0).toDouble();
    await _applyVolumes();
  }

  Future<void> setParticipantVolume(String userId, double value) async {
    _participantVolumes[userId] = value.clamp(0.0, 1.0).toDouble();
    await _applyVolumes();
  }

  Future<void> connect({
    required VoiceJoinModel join,
    required VoiceAudioSettingsModel audioSettings,
    required void Function(VoiceRoomSnapshot snapshot) onSnapshot,
    required void Function(String error) onError,
  }) async {
    await disconnect();
    _chatId = join.chatId;
    _onSnapshot = onSnapshot;
    onSnapshot(
      VoiceRoomSnapshot(
        status: 'connecting',
        participants: join.state.participants,
        speakingUserIds: const <String>{},
        isMuted: false,
        isCameraEnabled: false,
        isScreenShareEnabled: false,
        videoTiles: const <VoiceVideoTileModel>[],
        pingMs: _pingMs,
        packetLossPercent: _packetLossPercent,
      ),
    );
    try {
      final captureOptions = lk.AudioCaptureOptions(
        echoCancellation: audioSettings.echoCancellation,
        noiseSuppression: audioSettings.noiseSuppression,
        autoGainControl: audioSettings.autoGainControl,
      );
      final dynamic room = lk.Room(
        roomOptions: lk.RoomOptions(
          defaultAudioCaptureOptions: captureOptions,
        ),
      );
      _room = room;
      _listener = () => _emitSnapshot();
      room.addListener(_listener!);
      await room.connect(join.serverUrl, join.participantToken);
      await room.localParticipant.setMicrophoneEnabled(
        true,
        audioCaptureOptions: captureOptions,
      );
      _isMuted = false;
      _isCameraEnabled = false;
      _isScreenShareEnabled = false;
      _startStatsPolling();
      await _applyVolumes();
      _emitSnapshot();
    } catch (error) {
      onError(error.toString());
      await disconnect();
      onSnapshot(
        VoiceRoomSnapshot(
          status: 'error',
          participants: join.state.participants,
          speakingUserIds: const <String>{},
          isMuted: _isMuted,
          isCameraEnabled: _isCameraEnabled,
          isScreenShareEnabled: _isScreenShareEnabled,
          videoTiles: const <VoiceVideoTileModel>[],
          pingMs: _pingMs,
          packetLossPercent: _packetLossPercent,
        ),
      );
    }
  }

  Future<void> toggleCamera() async {
    final room = _room;
    if (room == null) {
      return;
    }
    final dynamic localParticipant = room.localParticipant;
    if (localParticipant == null) {
      return;
    }
    final nextEnabled = !_boolValue(localParticipant, 'isCameraEnabled');
    await localParticipant.setCameraEnabled(nextEnabled);
    _isCameraEnabled = nextEnabled;
    _emitSnapshot();
  }

  Future<void> setScreenShareEnabled(bool enabled, {String? desktopSourceId}) async {
    final room = _room;
    if (room == null) {
      return;
    }
    final dynamic localParticipant = room.localParticipant;
    if (localParticipant == null) {
      return;
    }
    if (!enabled) {
      await localParticipant.setScreenShareEnabled(false);
      _isScreenShareEnabled = false;
      _emitSnapshot();
      return;
    }
    if (lk.lkPlatformIsWebMobile()) {
      throw Exception('Screen sharing is not supported on mobile web.');
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      throw Exception('Screen sharing on iPhone requires additional ReplayKit setup and is not configured yet.');
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      throw Exception(
        'Screen sharing on Android is temporarily unavailable in this build because it requires a dedicated media projection foreground service.',
      );
    }
    if (lk.lkPlatformIsDesktop() && desktopSourceId != null && desktopSourceId.isNotEmpty) {
      final track = await lk.LocalVideoTrack.createScreenShareTrack(
        lk.ScreenShareCaptureOptions(
          sourceId: desktopSourceId,
          maxFrameRate: 15.0,
        ),
      );
      await localParticipant.publishVideoTrack(track);
    } else {
      await localParticipant.setScreenShareEnabled(true, captureScreenAudio: true);
    }
    _isScreenShareEnabled = true;
    _emitSnapshot();
  }

  Future<void> toggleMute() async {
    final room = _room;
    if (room == null) {
      return;
    }
    final nextMuted = !_isMuted;
    await room.localParticipant.setMicrophoneEnabled(!nextMuted);
    _isMuted = nextMuted;
    _emitSnapshot();
  }

  Future<void> disconnect() async {
    final room = _room;
    final listener = _listener;
    _listener = null;
    _room = null;
    _chatId = null;
    _isMuted = false;
    _isCameraEnabled = false;
    _isScreenShareEnabled = false;
    _onSnapshot = null;
    _statsPollTimer?.cancel();
    _statsPollTimer = null;
    _pingMs = null;
    _packetLossPercent = null;
    _participantDiagnosticsByUserId.clear();
    if (room != null) {
      if (listener != null) {
        room.removeListener(listener);
      }
      try {
        await room.disconnect();
      } catch (_) {}
    }
  }

  void _emitSnapshot() {
    final room = _room;
    final onSnapshot = _onSnapshot;
    if (room == null || onSnapshot == null) {
      return;
    }
    final dynamic localParticipant = room.localParticipant;
    final List<VoiceParticipantModel> participants = [];
    final List<VoiceVideoTileModel> videoTiles = [];
    if (localParticipant != null) {
      _isMuted = !_boolValue(localParticipant, 'isMicrophoneEnabled', fallback: true);
      _isCameraEnabled = _boolValue(localParticipant, 'isCameraEnabled');
      _isScreenShareEnabled = _boolValue(localParticipant, 'isScreenShareEnabled');
      participants.add(_participantFromLiveKit(localParticipant, isLocal: true));
      videoTiles.addAll(_videoTilesFromParticipant(localParticipant, isLocal: true));
    }
    final dynamic remoteParticipants = room.remoteParticipants;
    if (remoteParticipants is Map) {
      for (final participant in remoteParticipants.values) {
        participants.add(_participantFromLiveKit(participant));
        videoTiles.addAll(_videoTilesFromParticipant(participant));
      }
    }
    final speakingUserIds = <String>{};
    final dynamic activeSpeakers = room.activeSpeakers;
    if (activeSpeakers is Iterable) {
      for (final participant in activeSpeakers) {
        final identity = _stringValue(participant, 'identity');
        if (identity.isNotEmpty) {
          speakingUserIds.add(identity);
        }
      }
    } else {
      for (final participant in participants) {
        if (!_participantMutedHint(participant)) {
          continue;
        }
      }
    }
    onSnapshot(
      VoiceRoomSnapshot(
        status: _roomStatus(room),
        participants: participants,
        speakingUserIds: speakingUserIds,
        isMuted: _isMuted,
        isCameraEnabled: _isCameraEnabled,
        isScreenShareEnabled: _isScreenShareEnabled,
        videoTiles: videoTiles,
        pingMs: _pingMs,
        packetLossPercent: _packetLossPercent,
      ),
    );
    unawaited(_applyVolumes());
  }

  VoiceParticipantModel _participantFromLiveKit(dynamic participant, {bool isLocal = false}) {
    final user = _userFromLiveKitParticipant(participant);
    final connectionQuality = _connectionQualityValue(participant);
    final isMuted = isLocal ? _isMuted : !_boolValue(participant, 'isMicrophoneEnabled', fallback: true);
    final diagnostics = _participantDiagnosticsByUserId[user.id];
    return VoiceParticipantModel(
      user: user,
      joinedAt: DateTime.now(),
      isMuted: isMuted,
      connectionQuality: connectionQuality,
      hasCamera: _boolValue(participant, 'isCameraEnabled'),
      isScreenSharing: _boolValue(participant, 'isScreenShareEnabled'),
      pingMs: diagnostics?.pingMs,
      packetLossPercent: diagnostics?.packetLossPercent,
    );
  }

  UserModel _userFromLiveKitParticipant(dynamic participant) {
    final identity = _stringValue(participant, 'identity');
    final name = _stringValue(participant, 'name');
    final metadataRaw = _stringValue(participant, 'metadata');
    String? avatarUrl;
    if (metadataRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(metadataRaw);
        if (decoded is Map<String, dynamic>) {
          avatarUrl = decoded['avatar_url'] as String?;
        }
      } catch (_) {}
    }
    return UserModel(
      id: identity,
      email: '',
      displayName: name.isNotEmpty ? name : identity,
      isSystem: false,
      isAdmin: false,
      avatarUrl: avatarUrl,
      bio: null,
      isOnline: true,
      lastSeenAt: null,
    );
  }

  List<VoiceVideoTileModel> _videoTilesFromParticipant(dynamic participant, {bool isLocal = false}) {
    final dynamic videoTrackPublications = participant.videoTrackPublications;
    if (videoTrackPublications is! Iterable) {
      return const <VoiceVideoTileModel>[];
    }
    final user = _userFromLiveKitParticipant(participant);
    final tiles = <VoiceVideoTileModel>[];
    for (final publication in videoTrackPublications) {
      final dynamic track = publication.track;
      if (track is! lk.VideoTrack) {
        continue;
      }
      if (_boolValue(publication, 'muted')) {
        continue;
      }
      tiles.add(
        VoiceVideoTileModel(
          user: user,
          track: track,
          isLocal: isLocal,
          isScreenShare: _boolValue(publication, 'isScreenShare'),
        ),
      );
    }
    return tiles;
  }

  String _roomStatus(dynamic room) {
    final state = room.connectionState;
    final value = state?.toString() ?? '';
    if (value.contains('reconnecting')) {
      return 'reconnecting';
    }
    if (value.contains('connected')) {
      return 'connected';
    }
    if (value.contains('connecting')) {
      return 'connecting';
    }
    return 'disconnected';
  }

  String _stringValue(dynamic target, String field) {
    try {
      final dynamic value = _readField(target, field);
      return value?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  bool _boolValue(dynamic target, String field, {bool fallback = false}) {
    try {
      final dynamic value = _readField(target, field);
      if (value is bool) {
        return value;
      }
      if (value is Function) {
        final result = value();
        if (result is bool) {
          return result;
        }
      }
      return fallback;
    } catch (_) {
      return fallback;
    }
  }

  String _connectionQualityValue(dynamic target) {
    try {
      final dynamic value = _readField(target, 'connectionQuality');
      final normalized = value?.toString().split('.').last.toLowerCase() ?? 'unknown';
      switch (normalized) {
        case 'lost':
        case 'poor':
        case 'good':
        case 'excellent':
          return normalized;
        default:
          return 'unknown';
      }
    } catch (_) {
      return 'unknown';
    }
  }

  dynamic _readField(dynamic target, String field) {
    switch (field) {
      case 'identity':
        return target.identity;
      case 'name':
        return target.name;
      case 'metadata':
        return target.metadata;
      case 'isMicrophoneEnabled':
        return target.isMicrophoneEnabled;
      case 'isCameraEnabled':
        return target.isCameraEnabled;
      case 'isScreenShareEnabled':
        return target.isScreenShareEnabled;
      case 'connectionQuality':
        return target.connectionQuality;
      case 'muted':
        return target.muted;
      case 'isScreenShare':
        return target.isScreenShare;
      default:
        return null;
    }
  }

  bool _participantMutedHint(VoiceParticipantModel participant) => participant.isMuted;

  void _startStatsPolling() {
    _statsPollTimer?.cancel();
    _statsPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_updateDiagnostics()),
    );
    unawaited(_updateDiagnostics());
  }

  Future<void> _updateDiagnostics() async {
    final room = _room;
    if (room == null) {
      return;
    }
    try {
      final nextDiagnostics = <String, _VoiceDiagnostics>{};
      final dynamic localParticipant = room.localParticipant;
      if (localParticipant != null) {
        final localIdentity = _stringValue(localParticipant, 'identity');
        if (localIdentity.isNotEmpty) {
          nextDiagnostics[localIdentity] = await _readParticipantDiagnostics(localParticipant, isLocal: true);
        }
      }
      final dynamic remoteParticipants = room.remoteParticipants;
      if (remoteParticipants is Map) {
        for (final participant in remoteParticipants.values) {
          final identity = _stringValue(participant, 'identity');
          if (identity.isEmpty) {
            continue;
          }
          nextDiagnostics[identity] = await _readParticipantDiagnostics(participant);
        }
      }
      _participantDiagnosticsByUserId
        ..clear()
        ..addAll(nextDiagnostics);
      final localIdentity = _stringValue(localParticipant, 'identity');
      final localDiagnostics = localIdentity.isEmpty ? null : nextDiagnostics[localIdentity];
      _pingMs = localDiagnostics?.pingMs;
      _packetLossPercent = localDiagnostics?.packetLossPercent;
      _emitSnapshot();
    } catch (_) {}
  }

  Future<_VoiceDiagnostics> _readParticipantDiagnostics(dynamic participant, {bool isLocal = false}) async {
    final dynamic audioTrackPublications = participant?.audioTrackPublications;
    if (audioTrackPublications is! Iterable) {
      return const _VoiceDiagnostics();
    }
    for (final publication in audioTrackPublications) {
      final dynamic track = publication.track;
      if (track == null) {
        continue;
      }
      dynamic stats;
      try {
        stats = isLocal ? await track.getSenderStats() : await track.getReceiverStats();
      } catch (_) {
        continue;
      }
      final diagnostics = _diagnosticsFromStats(stats, isLocal: isLocal);
      if (diagnostics.pingMs != null || diagnostics.packetLossPercent != null) {
        return diagnostics;
      }
    }
    return const _VoiceDiagnostics();
  }

  _VoiceDiagnostics _diagnosticsFromStats(dynamic stats, {required bool isLocal}) {
    final roundTripTime = _extractStatNum(stats, 'roundTripTime')?.toDouble();
    final packetsLost = _extractStatNum(stats, 'packetsLost')?.toDouble();
    final packetBase = _extractStatNum(stats, isLocal ? 'packetsSent' : 'packetsReceived')?.toDouble() ??
        _extractStatNum(stats, 'packetsSent')?.toDouble();
    int? pingMs;
    double? packetLossPercent;
    if (roundTripTime != null) {
      pingMs = roundTripTime <= 10 ? (roundTripTime * 1000).round() : roundTripTime.round();
    }
    if (packetsLost != null && packetBase != null && (packetsLost + packetBase) > 0) {
      packetLossPercent = ((packetsLost / (packetsLost + packetBase)) * 100).clamp(0, 100).toDouble();
    } else if (packetsLost != null && packetsLost <= 0) {
      packetLossPercent = 0;
    }
    return _VoiceDiagnostics(
      pingMs: pingMs,
      packetLossPercent: packetLossPercent,
    );
  }

  num? _extractStatNum(dynamic stats, String field) {
    if (stats == null) {
      return null;
    }
    if (stats is Iterable) {
      for (final item in stats) {
        final value = _extractStatNum(item, field);
        if (value != null) {
          return value;
        }
      }
      return null;
    }
    if (stats is Map) {
      return _parseStatNum(stats[field]);
    }
    try {
      final dynamic values = stats.values;
      if (values is Map) {
        return _parseStatNum(values[field]);
      }
    } catch (_) {}
    try {
      switch (field) {
        case 'roundTripTime':
          return _parseStatNum(stats.roundTripTime);
        case 'packetsLost':
          return _parseStatNum(stats.packetsLost);
        case 'packetsSent':
          return _parseStatNum(stats.packetsSent);
        case 'packetsReceived':
          return _parseStatNum(stats.packetsReceived);
      }
    } catch (_) {}
    return null;
  }

  num? _parseStatNum(dynamic value) {
    if (value is num) {
      return value;
    }
    if (value is String) {
      return num.tryParse(value);
    }
    return null;
  }

  Future<void> _applyVolumes() async {
    final room = _room;
    if (room == null) {
      return;
    }
    final dynamic remoteParticipants = room.remoteParticipants;
    if (remoteParticipants is! Map) {
      return;
    }
    for (final participant in remoteParticipants.values) {
      final identity = _stringValue(participant, 'identity');
      final participantVolume = _participantVolumes[identity] ?? 1.0;
      final effectiveVolume = (_masterVolume * participantVolume).clamp(0.0, 1.0).toDouble();
      final dynamic audioTrackPublications = participant.audioTrackPublications;
      if (audioTrackPublications is! Iterable) {
        continue;
      }
      for (final publication in audioTrackPublications) {
        final dynamic track = publication.track;
        final dynamic mediaStreamTrack = track?.mediaStreamTrack;
        if (mediaStreamTrack == null) {
          continue;
        }
        try {
          await rtc.Helper.setVolume(effectiveVolume, mediaStreamTrack);
        } catch (_) {}
      }
    }
  }
}

class _VoiceDiagnostics {
  const _VoiceDiagnostics({
    this.pingMs,
    this.packetLossPercent,
  });

  final int? pingMs;
  final double? packetLossPercent;
}
