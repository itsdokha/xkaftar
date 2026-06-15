import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../models/message.dart';
import '../../services/api_client.dart';
import 'cached_network_media.dart';
import 'link_preview_card.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isOwn,
    required this.timeLabel,
    required this.deliveryStatus,
    required this.avatarLabel,
    this.avatarUrl,
    this.showSender = false,
    this.showAvatar = true,
    this.onReply,
    this.onOpenImage,
    this.onMediaLoaded,
    this.onOpenSenderProfile,
    this.onRetry,
    this.onShowReadReceipts,
    this.onShowMessageInsights,
    this.apiClient,
    this.onReact,
  });

  final MessageModel message;
  final bool isOwn;
  final String timeLabel;
  final String deliveryStatus;
  final String avatarLabel;
  final String? avatarUrl;
  final bool showSender;
  final bool showAvatar;
  final VoidCallback? onReply;
  final VoidCallback? onOpenImage;
  final VoidCallback? onMediaLoaded;
  final VoidCallback? onOpenSenderProfile;
  final VoidCallback? onRetry;
  final VoidCallback? onShowReadReceipts;
  final VoidCallback? onShowMessageInsights;
  final ApiClient? apiClient;
  final void Function(String emoji)? onReact;

  static final _urlRegex = RegExp(r'https?://[^\s<>]+', caseSensitive: false);
  static const _quickEmojis = ['\u2764\uFE0F', '\uD83D\uDC4D', '\uD83D\uDE02', '\uD83D\uDE2E', '\uD83D\uDE22', '\uD83D\uDE21'];

  static bool get _isDesktop {
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 430),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF121821),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFF263241)),
            ),
            child: Text(
              '${message.sender.displayName} ${message.body}'.trim(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB8C4D0),
              ),
            ),
          ),
        ),
      );
    }

    final background = isOwn ? const Color(0xFF1B232D) : const Color(0xFF141A22);
    final foreground = const Color(0xFFEDF1F5);
    final bubbleContent = Container(
      margin: EdgeInsets.only(
        top: showSender || showAvatar ? 5 : 3,
        bottom: 3,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: isOwn ? const Color(0xFF2A3441) : const Color(0xFF202936),
        ),
      ),
      child: Column(
        crossAxisAlignment: isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSender)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                message.sender.displayName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC7D0DA),
                ),
              ),
            ),
          if (message.replyTo != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 7),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: isOwn ? const Color(0xFF131A22) : const Color(0xFF0F141B),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: isOwn ? const Color(0xFF2A3441) : const Color(0xFF202734),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.replyTo!.sender.displayName,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFCFD6DE),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _replyPreview(message.replyTo!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8F98A3),
                    ),
                  ),
                ],
              ),
            ),
          if ((message.imageUrl ?? '').isNotEmpty)
            GestureDetector(
              onTap: onOpenImage,
              child: CachedImageView(
                url: message.imageUrl!,
                width: 248,
                height: 180,
                fit: BoxFit.cover,
                borderRadius: BorderRadius.circular(13),
                onLoaded: onMediaLoaded,
              ),
            ),
          if (message.isTriangleVideo)
            _TriangleVideoTile(
              videoUrl: message.videoUrl,
              isOwn: isOwn,
              caption: message.hasVideo ? 'Tap to play' : 'Uploading video...',
              onLoaded: onMediaLoaded,
            ),
          if (((message.imageUrl ?? '').isNotEmpty || message.isTriangleVideo) && message.body.isNotEmpty)
            const SizedBox(height: 7),
          if (message.body.isNotEmpty && !(message.isTriangleVideo && message.body == 'Triangle video'))
            _MessageText(
              text: message.body,
              style: TextStyle(
                fontSize: 13.5,
                color: foreground,
                height: 1.3,
              ),
            ),
          if (apiClient != null && message.body.isNotEmpty)
            Builder(
              builder: (context) {
                final match = _urlRegex.firstMatch(message.body);
                if (match == null) return const SizedBox.shrink();
                return LinkPreviewCard(
                  url: match.group(0)!,
                  apiClient: apiClient!,
                  isOwn: isOwn,
                );
              },
            ),
          const SizedBox(height: 4),
          if (deliveryStatus == 'failed' && onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 14, color: Color(0xFFFF7B7B)),
                  SizedBox(width: 4),
                  Text(
                    'Failed \u2022 Tap to retry',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFFFF7B7B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else
            GestureDetector(
              onTap: onShowReadReceipts,
              child: Text(
                _deliveryLabel(timeLabel, deliveryStatus),
                style: TextStyle(
                  fontSize: 11,
                  color: isOwn ? const Color(0xFF93A0AF) : const Color(0xFF8F98A3),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _groupedReactions().entries.map((entry) {
                  return GestureDetector(
                    onTap: onReact != null ? () => onReact!(entry.key) : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A2230),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2A3441)),
                      ),
                      child: Text(
                        '${entry.key} ${entry.value}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );

    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: _isDesktop
          ? GestureDetector(
              onDoubleTap: onReply,
              child: _DesktopContextMenuRegion(
                onCopy: message.body.isNotEmpty ? () => _copyText(context) : null,
                onReply: onReply,
                onOpenImage: onOpenImage,
                onShowMessageInsights: onShowMessageInsights,
                onReact: onReact,
                child: bubbleContent,
              ),
            )
          : GestureDetector(
              onLongPress: () => _showMobileContextMenu(context),
              child: bubbleContent,
            ),
    );

    if (isOwn) {
      if (!_isDesktop && onReply != null) {
        return _SwipeToReply(
          onReply: onReply!,
          child: Align(
            alignment: Alignment.centerRight,
            child: bubble,
          ),
        );
      }
      return Align(
        alignment: Alignment.centerRight,
        child: bubble,
      );
    }

    final row = Padding(
      padding: const EdgeInsets.only(right: 34),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 3),
            child: showAvatar
                ? InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onOpenSenderProfile,
                    child: CachedAvatar(
                      radius: 16,
                      label: avatarLabel,
                      imageUrl: avatarUrl,
                    ),
                  )
                : const SizedBox(width: 32),
          ),
          Flexible(child: bubble),
        ],
      ),
    );

    if (!_isDesktop && onReply != null) {
      return _SwipeToReply(
        onReply: onReply!,
        child: row,
      );
    }
    return row;
  }

  void _copyText(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.body));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(18),
          backgroundColor: const Color(0xFF121821),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF2A3644)),
          ),
          duration: const Duration(seconds: 2),
          content: const Text(
            'Copied to clipboard',
            style: TextStyle(color: Color(0xFFE6EDF5)),
          ),
        ),
      );
  }

  void _showMobileContextMenu(BuildContext context) {
    HapticFeedback.mediumImpact();
    final items = <Widget>[
      if (onReact != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _quickEmojis.map((emoji) {
              return GestureDetector(
                onTap: () {
                  Navigator.of(context).pop();
                  onReact!(emoji);
                },
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              );
            }).toList(),
          ),
        ),
      if (onReact != null) const Divider(height: 1, color: Color(0xFF2A3441)),
      if (onShowMessageInsights != null)
        ListTile(
          leading: const Icon(Icons.visibility_rounded, size: 20),
          title: const Text('Views and reactions'),
          dense: true,
          onTap: () {
            Navigator.of(context).pop();
            onShowMessageInsights!();
          },
        ),
      if (message.body.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.copy_rounded, size: 20),
          title: const Text('Copy text'),
          dense: true,
          onTap: () {
            Navigator.of(context).pop();
            _copyText(context);
          },
        ),
      if (onReply != null)
        ListTile(
          leading: const Icon(Icons.reply_rounded, size: 20),
          title: const Text('Reply'),
          dense: true,
          onTap: () {
            Navigator.of(context).pop();
            onReply!();
          },
        ),
      if (onOpenImage != null)
        ListTile(
          leading: const Icon(Icons.image_rounded, size: 20),
          title: const Text('Open image'),
          dense: true,
          onTap: () {
            Navigator.of(context).pop();
            onOpenImage!();
          },
        ),
    ];

    if (items.isEmpty) {
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF121821),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A3441),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              ...items,
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Map<String, int> _groupedReactions() {
    final counts = <String, int>{};
    for (final reaction in message.reactions) {
      counts[reaction.emoji] = (counts[reaction.emoji] ?? 0) + 1;
    }
    return counts;
  }

  String _replyPreview(MessageReplyModel reply) {
    if ((reply.videoUrl ?? '').isNotEmpty || reply.kind == 'triangle_video') {
      if (reply.body.isNotEmpty && reply.body != 'Triangle video') {
        return 'Triangle video - ${reply.body}';
      }
      return 'Triangle video';
    }
    if ((reply.imageUrl ?? '').isNotEmpty && reply.body.isNotEmpty) {
      return 'Photo - ${reply.body}';
    }
    if ((reply.imageUrl ?? '').isNotEmpty) {
      return 'Photo';
    }
    return reply.body;
  }

  String _deliveryLabel(String timeLabel, String deliveryStatus) {
    switch (deliveryStatus) {
      case 'sending':
        return '$timeLabel  ...';
      case 'retrying':
        return '$timeLabel  retry';
      case 'failed':
        return '$timeLabel  !';
      case 'read':
        return '$timeLabel  \u2713\u2713';
      case 'sent':
        return '$timeLabel  \u2713';
      default:
        return timeLabel;
    }
  }
}

class _TriangleVideoTile extends StatefulWidget {
  const _TriangleVideoTile({
    required this.videoUrl,
    required this.isOwn,
    required this.caption,
    this.onLoaded,
  });

  final String? videoUrl;
  final bool isOwn;
  final String caption;
  final VoidCallback? onLoaded;

  @override
  State<_TriangleVideoTile> createState() => _TriangleVideoTileState();
}

class _TriangleVideoTileState extends State<_TriangleVideoTile> {
  VideoPlayerController? _controller;
  Timer? _controlsTimer;
  bool _loading = false;
  bool _showControls = true;
  String? _error;

  bool get _hasVideo => (widget.videoUrl ?? '').isNotEmpty;
  bool get _isInitialized => _controller?.value.isInitialized ?? false;

  @override
  void dispose() {
    _controlsTimer?.cancel();
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (!_hasVideo || _loading) {
      return;
    }
    if (!_isInitialized) {
      await _initializeAndPlay();
      return;
    }
    final controller = _controller!;
    if (controller.value.isPlaying) {
      await controller.pause();
      _controlsTimer?.cancel();
      if (mounted) {
        setState(() {
          _showControls = true;
        });
      }
      return;
    }
    await controller.play();
    _scheduleControlsHide();
    if (mounted) {
      setState(() {
        _showControls = true;
      });
    }
  }

  Future<void> _initializeAndPlay() async {
    final rawUrl = widget.videoUrl;
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null) {
      setState(() {
        _error = 'Could not open the video';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _showControls = true;
    });
    final controller = VideoPlayerController.networkUrl(uri);
    try {
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(_handleControllerChanged);
      await controller.play();
      await _controller?.dispose();
      _controller = controller;
      widget.onLoaded?.call();
      _scheduleControlsHide();
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
    } catch (_) {
      await controller.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Could not load the video';
      });
    }
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.position >= controller.value.duration &&
        controller.value.duration > Duration.zero &&
        !controller.value.isPlaying) {
      _showControls = true;
    }
    setState(() {});
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      final controller = _controller;
      if (controller != null && controller.value.isPlaying) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isOwn ? const Color(0xFF4A88A7) : const Color(0xFF316079);
    final topGlow = widget.isOwn ? const Color(0xFF76ECDA) : const Color(0xFF5FC3E0);
    final bottomGlow = widget.isOwn ? const Color(0xFF14384A) : const Color(0xFF0F2432);
    final controller = _controller;
    final isPlaying = controller?.value.isPlaying ?? false;
    final isBuffering = controller?.value.isBuffering ?? false;
    final progress = _isInitialized && controller!.value.duration > Duration.zero
        ? controller.value.position.inMilliseconds / controller.value.duration.inMilliseconds
        : 0.0;

    return GestureDetector(
      onTap: _handleTap,
      child: SizedBox(
        width: 248,
        height: 214,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                    gradient: RadialGradient(
                    center: const Alignment(0, -0.15),
                    radius: 0.92,
                    colors: [
                      topGlow.withOpacity(0.22),
                      bottomGlow.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ClipPath(
                clipper: _TriangleClipper(),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        topGlow.withOpacity(0.9),
                        bottomGlow,
                      ],
                    ),
                    border: Border.all(color: borderColor, width: 1.7),
                    boxShadow: [
                      BoxShadow(
                        color: topGlow.withOpacity(0.24),
                        blurRadius: 22,
                        spreadRadius: -12,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_isInitialized && controller != null)
                        FittedBox(
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: controller.value.size.width,
                            height: controller.value.size.height,
                            child: VideoPlayer(controller),
                          ),
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                topGlow.withOpacity(0.45),
                                bottomGlow.withOpacity(0.92),
                              ],
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0x33070F16),
                                const Color(0x00070F16),
                                const Color(0xD9070F16),
                              ],
                              stops: const [0.0, 0.45, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 16,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xCC071116),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: borderColor.withOpacity(0.9)),
                            ),
                            child: Text(
                              _isInitialized
                                  ? (isPlaying ? 'PLAYING NOW' : 'READY TO PLAY')
                                  : 'TRIANGLE VIDEO',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: Color(0xFFF0FAFF),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_loading || isBuffering)
                        const Center(
                          child: SizedBox(
                            width: 34,
                            height: 34,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.8,
                              color: Color(0xFFF5FBFF),
                            ),
                          ),
                        )
                      else if (_error != null)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 30),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFF3F7FA),
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                          ),
                        )
                      else if (_showControls || !_isInitialized || !isPlaying)
                        Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 68,
                            height: 68,
                            decoration: BoxDecoration(
                              color: _hasVideo ? const Color(0xEAF6FCFF) : const Color(0x88EAF6FC),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2),
                                  blurRadius: 16,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Icon(
                              _hasVideo && _isInitialized && isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 38,
                              color: _hasVideo ? const Color(0xFF092130) : const Color(0xFF5C6975),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 18,
                        right: 18,
                        bottom: 20,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isInitialized)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  minHeight: 4,
                                  backgroundColor: const Color(0x4DF5FBFF),
                                  valueColor: AlwaysStoppedAnimation<Color>(topGlow),
                                ),
                              ),
                            if (_isInitialized) const SizedBox(height: 8),
                            Text(
                              _error ??
                                  (_hasVideo
                                      ? (widget.caption.trim().isEmpty ? 'Tap to play' : widget.caption)
                                      : 'Uploading video...'),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFF4F7FA),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TriangleClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _DesktopContextMenuRegion extends StatelessWidget {
  const _DesktopContextMenuRegion({
    required this.child,
    this.onCopy,
    this.onReply,
    this.onOpenImage,
    this.onShowMessageInsights,
    this.onReact,
  });

  final Widget child;
  final VoidCallback? onCopy;
  final VoidCallback? onReply;
  final VoidCallback? onOpenImage;
  final VoidCallback? onShowMessageInsights;
  final void Function(String emoji)? onReact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) {
        _showDesktopContextSheet(context, details.globalPosition).then((value) {
          if (value == 'copy') onCopy?.call();
          if (value == 'reply') onReply?.call();
          if (value == 'image') onOpenImage?.call();
          if (value == 'insights') onShowMessageInsights?.call();
          if (value != null && value.startsWith('react:')) {
            onReact?.call(value.substring('react:'.length));
          }
        });
      },
      child: child,
    );
  }

  Future<String?> _showDesktopContextSheet(BuildContext context, Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlay.size;
    const menuWidth = 220.0;
    const estimatedMenuHeight = 280.0;
    final maxLeft = (overlaySize.width - menuWidth - 12.0).clamp(12.0, double.infinity).toDouble();
    final maxTop = (overlaySize.height - estimatedMenuHeight - 12.0).clamp(12.0, double.infinity).toDouble();
    final left = globalPosition.dx.clamp(12.0, maxLeft).toDouble();
    final top = globalPosition.dy.clamp(12.0, maxTop).toDouble();

    return showGeneralDialog<String>(
      context: context,
      barrierLabel: 'Message menu',
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      pageBuilder: (dialogContext, _, __) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: const Color(0xFF1B232D),
                elevation: 10,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF2A3441)),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: menuWidth),
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (onReact != null) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: MessageBubble._quickEmojis.map((emoji) {
                                return InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => Navigator.of(dialogContext).pop('react:$emoji'),
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFF2A3441)),
                        ],
                        if (onCopy != null)
                          _DesktopContextAction(
                            label: 'Copy text',
                            onTap: () => Navigator.of(dialogContext).pop('copy'),
                          ),
                        if (onReply != null)
                          _DesktopContextAction(
                            label: 'Reply',
                            onTap: () => Navigator.of(dialogContext).pop('reply'),
                          ),
                        if (onOpenImage != null)
                          _DesktopContextAction(
                            label: 'Open image',
                            onTap: () => Navigator.of(dialogContext).pop('image'),
                          ),
                        if (onShowMessageInsights != null)
                          _DesktopContextAction(
                            label: 'Views and reactions',
                            onTap: () => Navigator.of(dialogContext).pop('insights'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DesktopContextAction extends StatelessWidget {
  const _DesktopContextAction({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFE6EDF5),
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _MessageText extends StatefulWidget {
  const _MessageText({
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  State<_MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<_MessageText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in MessageBubble._urlRegex.allMatches(widget.text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          unawaited(_openUrl(context, url));
        };
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: widget.style.copyWith(
            color: const Color(0xFF8FD1FF),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFF8FD1FF),
          ),
          recognizer: recognizer,
        ),
      );
      cursor = match.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return SelectionArea(
      child: RichText(
        text: TextSpan(
          style: widget.style,
          children: spans.isEmpty ? <InlineSpan>[TextSpan(text: widget.text)] : spans,
        ),
      ),
    );
  }

  Future<void> _openUrl(BuildContext context, String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Could not open the link'),
          ),
        );
    }
  }
}

class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.onReply,
    required this.child,
  });

  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _dragExtent = 0;
  static const _threshold = 60.0;
  bool _triggered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragExtent = (_dragExtent + details.primaryDelta!).clamp(0, 100);
        });
        if (_dragExtent >= _threshold && !_triggered) {
          _triggered = true;
          HapticFeedback.lightImpact();
        }
      },
      onHorizontalDragEnd: (_) {
        if (_dragExtent >= _threshold) {
          widget.onReply();
        }
        _triggered = false;
        setState(() => _dragExtent = 0);
      },
      onHorizontalDragCancel: () {
        _triggered = false;
        setState(() => _dragExtent = 0);
      },
      child: Stack(
        children: [
          if (_dragExtent > 10)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Opacity(
                    opacity: (_dragExtent / _threshold).clamp(0, 1),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 22,
                      color: _dragExtent >= _threshold
                          ? const Color(0xFFF5F7FB)
                          : const Color(0xFF8F98A3),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragExtent, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
