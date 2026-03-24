import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import 'cached_network_media.dart';

class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({
    super.key,
    required this.url,
    required this.apiClient,
    this.isOwn = false,
  });

  final String url;
  final ApiClient apiClient;
  final bool isOwn;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  Future<LinkPreviewResult?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.apiClient.fetchLinkPreview(widget.url);
  }

  @override
  void didUpdateWidget(LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = widget.apiClient.fetchLinkPreview(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreviewResult?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final result = snapshot.data;
        if (result == null) {
          return const SizedBox.shrink();
        }
        final bg = widget.isOwn ? const Color(0xFF131A22) : const Color(0xFF0F141B);
        final border = widget.isOwn ? const Color(0xFF2A3441) : const Color(0xFF202734);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.imageUrl != null)
                CachedImageView(
                  url: result.imageUrl!,
                  width: double.infinity,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              Padding(
                padding: const EdgeInsets.all(9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (result.siteName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          result.siteName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8F98A3),
                          ),
                        ),
                      ),
                    if (result.title != null)
                      Text(
                        result.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFCFD6DE),
                          height: 1.3,
                        ),
                      ),
                    if (result.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          result.description!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF8F98A3),
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
