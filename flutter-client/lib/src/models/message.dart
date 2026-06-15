import '../core/json_utils.dart';
import 'user.dart';

class MessageReplyModel {
  const MessageReplyModel({
    required this.id,
    required this.sender,
    required this.body,
    required this.createdAt,
    this.kind = 'user',
    this.imageUrl,
    this.videoUrl,
  });

  factory MessageReplyModel.fromJson(Map<String, dynamic> json) {
    return MessageReplyModel(
      id: json['id'] as String,
      sender: UserModel.fromJson(json['sender'] as Map<String, dynamic>),
      body: json['body'] as String? ?? '',
      createdAt: parseDateTime(json['created_at']) ?? DateTime.now(),
      kind: json['kind'] as String? ?? 'user',
      imageUrl: json['image_url'] as String?,
      videoUrl: json['video_url'] as String?,
    );
  }

  final String id;
  final UserModel sender;
  final String body;
  final DateTime createdAt;
  final String kind;
  final String? imageUrl;
  final String? videoUrl;

  MessageReplyModel copyWith({
    String? id,
    UserModel? sender,
    String? body,
    DateTime? createdAt,
    String? kind,
    String? imageUrl,
    String? videoUrl,
  }) {
    return MessageReplyModel(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      kind: kind ?? this.kind,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
    );
  }
}

class MessageReactionModel {
  const MessageReactionModel({
    required this.emoji,
    required this.user,
    required this.createdAt,
  });

  factory MessageReactionModel.fromJson(Map<String, dynamic> json) {
    return MessageReactionModel(
      emoji: json['emoji'] as String,
      user: UserModel.fromJson(json['user'] as Map<String, dynamic>),
      createdAt: parseDateTime(json['created_at']) ?? DateTime.now(),
    );
  }

  final String emoji;
  final UserModel user;
  final DateTime createdAt;

  MessageReactionModel copyWith({
    String? emoji,
    UserModel? user,
    DateTime? createdAt,
  }) {
    return MessageReactionModel(
      emoji: emoji ?? this.emoji,
      user: user ?? this.user,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class MessageModel {
  const MessageModel({
    required this.id,
    required this.chatId,
    required this.sender,
    required this.body,
    required this.createdAt,
    this.kind = 'user',
    this.imageUrl,
    this.videoUrl,
    this.replyTo,
    this.reactions = const [],
    this.localState = MessageLocalState.none,
    this.localRetryCount = 0,
  });

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      sender: UserModel.fromJson(json['sender'] as Map<String, dynamic>),
      body: json['body'] as String? ?? '',
      createdAt: parseDateTime(json['created_at']) ?? DateTime.now(),
      kind: json['kind'] as String? ?? 'user',
      imageUrl: json['image_url'] as String?,
      videoUrl: json['video_url'] as String?,
      replyTo: json['reply_to'] is Map<String, dynamic>
          ? MessageReplyModel.fromJson(json['reply_to'] as Map<String, dynamic>)
          : null,
      reactions: (json['reactions'] as List<dynamic>?)
              ?.map((r) => MessageReactionModel.fromJson(r as Map<String, dynamic>))
              .toList() ??
          const [],
      localState: MessageLocalState.none,
      localRetryCount: 0,
    );
  }

  final String id;
  final String chatId;
  final UserModel sender;
  final String body;
  final DateTime createdAt;
  final String kind;
  final String? imageUrl;
  final String? videoUrl;
  final MessageReplyModel? replyTo;
  final List<MessageReactionModel> reactions;
  final MessageLocalState localState;
  final int localRetryCount;

  bool get isSystem => kind == 'system';
  bool get hasImage => (imageUrl ?? '').isNotEmpty;
  bool get hasVideo => (videoUrl ?? '').isNotEmpty;
  bool get isTriangleVideo => kind == 'triangle_video';

  MessageModel copyWith({
    String? id,
    String? chatId,
    UserModel? sender,
    String? body,
    DateTime? createdAt,
    String? kind,
    String? imageUrl,
    String? videoUrl,
    MessageReplyModel? replyTo,
    List<MessageReactionModel>? reactions,
    MessageLocalState? localState,
    int? localRetryCount,
  }) {
    return MessageModel(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      sender: sender ?? this.sender,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      kind: kind ?? this.kind,
      imageUrl: imageUrl ?? this.imageUrl,
      videoUrl: videoUrl ?? this.videoUrl,
      replyTo: replyTo ?? this.replyTo,
      reactions: reactions ?? this.reactions,
      localState: localState ?? this.localState,
      localRetryCount: localRetryCount ?? this.localRetryCount,
    );
  }
}

enum MessageLocalState {
  none,
  sending,
  retrying,
  failed,
}

class MessagePageModel {
  const MessagePageModel({
    required this.items,
    required this.total,
    required this.hasMore,
    this.nextBeforeMessageId,
  });

  factory MessagePageModel.fromJson(Map<String, dynamic> json) {
    return MessagePageModel(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((item) => MessageModel.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      hasMore: json['has_more'] as bool? ?? false,
      nextBeforeMessageId: json['next_before_message_id'] as String?,
    );
  }

  final List<MessageModel> items;
  final int total;
  final bool hasMore;
  final String? nextBeforeMessageId;
}
