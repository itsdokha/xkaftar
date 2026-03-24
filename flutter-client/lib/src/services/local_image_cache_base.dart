import 'dart:typed_data';

abstract class LocalImageCache {
  Future<Uint8List?> loadBytes(String url);
}
