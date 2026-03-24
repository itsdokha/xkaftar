import 'package:flutter/foundation.dart';

class MobileVoiceBackground {
  const MobileVoiceBackground();

  Future<bool> enable() async {
    if (!_isAndroidMobile()) {
      return true;
    }
    // Android 15+/targetSdk 36 aggressively restricts starting this
    // plugin-managed foreground service for microphone/mediaProjection.
    // Let voice/video continue without forcing the extra service, rather
    // than crashing the whole app when joining voice or starting share.
    return true;
  }

  Future<void> disable() async {
    if (!_isAndroidMobile()) {
      return;
    }
  }

  bool _isAndroidMobile() {
    if (kIsWeb) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.android;
  }
}
