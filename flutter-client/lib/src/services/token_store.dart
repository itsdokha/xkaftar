import 'package:shared_preferences/shared_preferences.dart';

class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;
}

class TokenStore {
  const TokenStore();

  static const _accessTokenKey = 'kaftar_access_token';
  static const _refreshTokenKey = 'kaftar_refresh_token';

  Future<StoredTokens?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final accessToken = preferences.getString(_accessTokenKey);
    final refreshToken = preferences.getString(_refreshTokenKey);
    if (accessToken == null || refreshToken == null) {
      return null;
    }
    return StoredTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> save(StoredTokens tokens) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_accessTokenKey, tokens.accessToken);
    await preferences.setString(_refreshTokenKey, tokens.refreshToken);
  }

  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_accessTokenKey);
    await preferences.remove(_refreshTokenKey);
  }
}
