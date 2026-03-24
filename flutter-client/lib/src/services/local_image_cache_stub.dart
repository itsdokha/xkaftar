import 'dart:typed_data';

import 'local_image_cache_base.dart';

class _NoopLocalImageCache implements LocalImageCache {
  @override
  Future<Uint8List?> loadBytes(String url) async => null;
}

LocalImageCache createLocalImageCache() => _NoopLocalImageCache();
