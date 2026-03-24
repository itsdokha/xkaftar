import '../core/json_utils.dart';

class UserModel {
  const UserModel({
    required this.id,
    required this.email,
    required this.displayName,
    required this.isSystem,
    required this.isAdmin,
    this.avatarUrl,
    this.bio,
    required this.isOnline,
    this.lastSeenAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['display_name'] as String,
      isSystem: json['is_system'] as bool? ?? false,
      isAdmin: json['is_admin'] as bool? ?? false,
      avatarUrl: json['avatar_url'] as String?,
      bio: json['bio'] as String?,
      isOnline: json['is_online'] as bool? ?? false,
      lastSeenAt: parseDateTime(json['last_seen_at']),
    );
  }

  final String id;
  final String email;
  final String displayName;
  final bool isSystem;
  final bool isAdmin;
  final String? avatarUrl;
  final String? bio;
  final bool isOnline;
  final DateTime? lastSeenAt;

  UserModel copyWith({
    String? id,
    String? email,
    String? displayName,
    bool? isSystem,
    bool? isAdmin,
    String? avatarUrl,
    String? bio,
    bool? isOnline,
    DateTime? lastSeenAt,
  }) {
    return UserModel(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      isSystem: isSystem ?? this.isSystem,
      isAdmin: isAdmin ?? this.isAdmin,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      isOnline: isOnline ?? this.isOnline,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}
