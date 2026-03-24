class AppConfig {
  const AppConfig({
    required this.environment,
    required this.apiBaseUrl,
  });

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      environment: String.fromEnvironment(
        'APP_ENV',
        defaultValue: 'development',
      ),
      apiBaseUrl: String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://127.0.0.1:8000',
      ),
    );
  }

  final String environment;
  final String apiBaseUrl;
}
