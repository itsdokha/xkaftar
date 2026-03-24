import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/local_image_cache.dart';
import '../../services/local_image_cache_base.dart';

final LocalImageCache _localImageCache = createLocalImageCache();

class CachedImageView extends StatefulWidget {
  const CachedImageView({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.errorText = 'Image unavailable',
    this.backgroundColor = const Color(0xFF0F141B),
    this.onLoaded,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final String errorText;
  final Color backgroundColor;
  final VoidCallback? onLoaded;

  @override
  State<CachedImageView> createState() => _CachedImageViewState();
}

class _CachedImageViewState extends State<CachedImageView> {
  late Future<Uint8List?> _future;
  bool _loadNotified = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant CachedImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = _load();
      _loadNotified = false;
    }
  }

  Future<Uint8List?> _load() {
    if (kIsWeb) {
      return Future<Uint8List?>.value(null);
    }
    return _localImageCache.loadBytes(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return _clip(
        Image.network(
          widget.url,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          loadingBuilder: (context, child, progress) {
            if (progress == null) {
              _notifyLoaded();
              return child;
            }
            return _placeholder();
          },
          errorBuilder: (_, _, _) => _errorPlaceholder(context),
        ),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _placeholder();
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _errorPlaceholder(context);
        }
        _notifyLoaded();
        return _clip(
          Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => _errorPlaceholder(context),
          ),
        );
      },
    );
  }

  void _notifyLoaded() {
    if (_loadNotified) {
      return;
    }
    _loadNotified = true;
    final callback = widget.onLoaded;
    if (callback == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        callback();
      }
    });
  }

  Widget _clip(Widget child) {
    final content = SizedBox(
      width: widget.width,
      height: widget.height,
      child: child,
    );
    final radius = widget.borderRadius;
    if (radius == null) {
      return content;
    }
    return ClipRRect(
      borderRadius: radius,
      child: content,
    );
  }

  Widget _placeholder() {
    return _clip(
      Container(
        width: widget.width,
        height: widget.height,
        color: widget.backgroundColor,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    );
  }

  Widget _errorPlaceholder(BuildContext context) {
    return _clip(
      Container(
        width: widget.width,
        height: widget.height,
        color: widget.backgroundColor,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          widget.errorText,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF8F98A3),
              ),
        ),
      ),
    );
  }
}

class CachedAvatar extends StatelessWidget {
  const CachedAvatar({
    super.key,
    required this.label,
    this.imageUrl,
    this.radius = 20,
    this.backgroundColor = const Color(0xFFF5F7FB),
    this.foregroundColor = const Color(0xFF0B0D10),
  });

  final String label;
  final String? imageUrl;
  final double radius;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final normalizedLabel = label.trim();
    final firstLetter = normalizedLabel.isEmpty ? '?' : normalizedLabel[0].toUpperCase();
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        child: Text(
          firstLetter,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    }
    return ClipOval(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: radius * 2,
            height: radius * 2,
            color: backgroundColor,
          ),
          CachedImageView(
            url: url,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorText: firstLetter,
            backgroundColor: backgroundColor,
          ),
        ],
      ),
    );
  }
}
