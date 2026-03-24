import 'dart:io';
import 'dart:typed_data';

import 'local_image_cache_base.dart';

class _IoLocalImageCache implements LocalImageCache {
  final Map<String, Uint8List> _memory = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  Directory? _cacheDirectory;

  @override
  Future<Uint8List?> loadBytes(String url) {
    final cached = _memory[url];
    if (cached != null) {
      return Future<Uint8List?>.value(cached);
    }
    final pending = _pending[url];
    if (pending != null) {
      return pending;
    }
    final future = _loadBytesInternal(url);
    _pending[url] = future;
    future.whenComplete(() {
      _pending.remove(url);
    });
    return future;
  }

  Future<Uint8List?> _loadBytesInternal(String url) async {
    try {
      final cacheFile = await _cacheFileForUrl(url);
      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (bytes.isNotEmpty) {
          _memory[url] = bytes;
          return bytes;
        }
      }
      final bytes = await _download(url);
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      _memory[url] = bytes;
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _download(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = true;
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<File> _cacheFileForUrl(String url) async {
    final directory = await _getCacheDirectory();
    final extension = _safeExtension(url);
    return File('${directory.path}${Platform.pathSeparator}${_hashUrl(url)}$extension');
  }

  Future<Directory> _getCacheDirectory() async {
    final existing = _cacheDirectory;
    if (existing != null) {
      return existing;
    }
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}kaftar_image_cache',
    );
    await directory.create(recursive: true);
    _cacheDirectory = directory;
    return directory;
  }

  String _safeExtension(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? url;
    final index = path.lastIndexOf('.');
    if (index < 0 || index == path.length - 1) {
      return '.bin';
    }
    final candidate = path.substring(index).toLowerCase();
    final normalized = candidate.replaceAll(RegExp(r'[^a-z0-9.]'), '');
    if (normalized.length < 2 || normalized.length > 6) {
      return '.bin';
    }
    return normalized;
  }

  String _hashUrl(String url) {
    var hash = 0x811C9DC5;
    for (final codeUnit in url.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }
}

LocalImageCache createLocalImageCache() => _IoLocalImageCache();
