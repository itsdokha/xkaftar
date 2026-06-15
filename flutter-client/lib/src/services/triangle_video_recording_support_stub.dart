bool get isTriangleVideoRecordingSupported => false;
bool get usesNativeTriangleVideoRecorder => false;

Future<String> createTriangleVideoTempPath() async {
  throw UnsupportedError('Triangle video recording is not supported on this platform.');
}

Future<List<int>> readTriangleVideoBytes(String path) async {
  throw UnsupportedError('Triangle video recording is not supported on this platform.');
}

Future<String> startNativeTriangleVideoRecording() async {
  throw UnsupportedError('Triangle video recording is not supported on this platform.');
}

Future<String> stopNativeTriangleVideoRecording() async {
  throw UnsupportedError('Triangle video recording is not supported on this platform.');
}

Future<void> deleteTriangleVideoFile(String path) async {}
