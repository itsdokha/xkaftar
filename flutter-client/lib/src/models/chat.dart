import '../core/json_utils.dart';
import 'message.dart';
import 'user.dart';

class ChatMemberModel {
  const ChatMemberModel({
    required this.id,
    required this.role,
    required this.joinedAt,
    required this.user,
    this.lastReadAt,
  });

  factory ChatMemberModel.fromJson(Map<String, dynamic> json) {
    return ChatMemberModel(
      id: json['id'] as String,
      role: json['role'] as String,
      joinedAt: parseDateTime(json['joined_at']) ?? DateTime.now(),
      user: UserModel.fromJson(json['user'] as Map<String, dynamic>),
      lastReadAt: parseDateTime(json['last_read_at']),
    );
  }

  final String id;
  final String role;
  final DateTime joinedAt;
  final UserModel user;
  final DateTime? lastReadAt;

  ChatMemberModel copyWith({
    String? id,
    String? role,
    DateTime? joinedAt,
    UserModel? user,
    DateTime? lastReadAt,
  }) {
    return ChatMemberModel(
      id: id ?? this.id,
      role: role ?? this.role,
      joinedAt: joinedAt ?? this.joinedAt,
      user: user ?? this.user,
      lastReadAt: lastReadAt ?? this.lastReadAt,
    );
  }
}

class ChatModel {
  const ChatModel({
    required this.id,
    required this.type,
    required this.createdById,
    required this.createdAt,
    required this.updatedAt,
    required this.members,
    required this.notificationsEnabled,
    this.title,
    this.iconUrl,
    this.lastMessage,
    required this.unreadCount,
  });

  factory ChatModel.fromJson(Map<String, dynamic> json) {
    return ChatModel(
      id: json['id'] as String,
      type: json['type'] as String,
      title: json['title'] as String?,
      iconUrl: json['icon_url'] as String?,
      createdById: json['created_by_id'] as String,
      createdAt: parseDateTime(json['created_at']) ?? DateTime.now(),
      updatedAt: parseDateTime(json['updated_at']) ?? DateTime.now(),
      members: (json['members'] as List<dynamic>? ?? const [])
          .map((item) => ChatMemberModel.fromJson(item as Map<String, dynamic>))
          .toList(),
      notificationsEnabled: json['notifications_enabled'] as bool? ?? true,
      lastMessage: json['last_message'] is Map<String, dynamic>
          ? MessageModel.fromJson(json['last_message'] as Map<String, dynamic>)
          : null,
      unreadCount: json['unread_count'] as int? ?? 0,
    );
  }

  final String id;
  final String type;
  final String? title;
  final String? iconUrl;
  final String createdById;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMemberModel> members;
  final bool notificationsEnabled;
  final MessageModel? lastMessage;
  final int unreadCount;

  ChatModel copyWith({
    String? id,
    String? type,
    String? title,
    String? iconUrl,
    String? createdById,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMemberModel>? members,
    bool? notificationsEnabled,
    MessageModel? lastMessage,
    int? unreadCount,
  }) {
    return ChatModel(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      iconUrl: iconUrl ?? this.iconUrl,
      createdById: createdById ?? this.createdById,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      members: members ?? this.members,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
