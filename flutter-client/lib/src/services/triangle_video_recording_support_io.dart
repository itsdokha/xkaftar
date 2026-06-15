import 'dart:io';

import 'package:flutter/services.dart';

bool get isTriangleVideoRecordingSupported =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;

bool get usesNativeTriangleVideoRecorder => Platform.isWindows;

const MethodChannel _triangleVideoRecorderChannel =
    MethodChannel('kaftar/triangle_video_recorder');

Future<String> createTriangleVideoTempPath() async {
  final directory = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}kaftar-triangle-videos');
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return '${directory.path}${Platform.pathSeparator}triangle-${DateTime.now().microsecondsSinceEpoch}.mp4';
}

Future<List<int>> readTriangleVideoBytes(String path) {
  return File(path).readAsBytes();
}

Future<String> startNativeTriangleVideoRecording() async {
  final result = await _triangleVideoRecorderChannel.invokeMethod<String>(
    'startTriangleVideoRecording',
  );
  if (result == null || result.isEmpty) {
    throw StateError('Windows recorder did not return a file path.');
  }
  return result;
}

Future<String> stopNativeTriangleVideoRecording() async {
  final result = await _triangleVideoRecorderChannel.invokeMethod<String>(
    'stopTriangleVideoRecording',
  );
  if (result == null || result.isEmpty) {
    throw StateError('Windows recorder did not return a file path.');
  }
  return result;
}

Future<void> deleteTriangleVideoFile(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}
