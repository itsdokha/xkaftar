import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

bool get isTriangleVideoRecordingSupported => true;
bool get usesNativeTriangleVideoRecorder => false;

Future<String> createTriangleVideoTempPath() async {
  throw UnsupportedError('Triangle video temp files are not used on web.');
}

Future<List<int>> readTriangleVideoBytes(String path) async {
  final response = await html.HttpRequest.request(
    path,
    responseType: 'blob',
  );
  final blob = response.response as html.Blob;
  final completer = Completer<List<int>>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result is ByteBuffer) {
      completer.complete(Uint8List.view(result));
      return;
    }
    if (result is Uint8List) {
      completer.complete(result);
      return;
    }
    completer.completeError(
      StateError('Unexpected web recorder payload: ${result.runtimeType}'),
    );
  });
  reader.onError.listen((_) {
    completer.completeError(
      StateError('Could not read recorded web video bytes.'),
    );
  });
  reader.readAsArrayBuffer(blob);
  return completer.future;
}

Future<String> startNativeTriangleVideoRecording() async {
  throw UnsupportedError('Triangle video native recording is not used on web.');
}

Future<String> stopNativeTriangleVideoRecording() async {
  throw UnsupportedError('Triangle video native recording is not used on web.');
}

Future<void> deleteTriangleVideoFile(String path) async {
  html.Url.revokeObjectUrl(path);
}
