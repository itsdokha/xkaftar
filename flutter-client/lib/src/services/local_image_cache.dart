import 'local_image_cache_base.dart';
import 'local_image_cache_stub.dart'
    if (dart.library.io) 'local_image_cache_io.dart' as impl;

LocalImageCache createLocalImageCache() => impl.createLocalImageCache();
