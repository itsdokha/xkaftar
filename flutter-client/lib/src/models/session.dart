import 'user.dart';

class SessionModel {
  const SessionModel({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
  });

  factory SessionModel.fromJson(Map<String, dynamic> json) {
    final tokens = json['tokens'] as Map<String, dynamic>;
    return SessionModel(
      user: UserModel.fromJson(json['user'] as Map<String, dynamic>),
      accessToken: tokens['access_token'] as String,
      refreshToken: tokens['refresh_token'] as String,
    );
  }

  final UserModel user;
  final String accessToken;
  final String refreshToken;
}
